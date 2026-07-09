import ARKit
import CoreVideo
import Foundation
import simd

struct DepthCalibrationBaseline {
    let depthMapSize: PixelSize
    let depths: [Float]
    let centerPixel: PixelPoint
    let workingRadiusPixels: Double
    let workingRadiusMeters: Double
    let medianDepthMeters: Double
    let sampleCount: Int
}

struct DepthCalibrationBounds: Equatable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var widthPixels: Int {
        maxX - minX + 1
    }

    var heightPixels: Int {
        maxY - minY + 1
    }
}

struct DepthBrainCalibrationEstimate {
    let centerWorld: HandJoint3D
    let widthMeters: Double
    let depthMeters: Double
    let heightMeters: Double
    let topSurfaceDepthMeters: Double
    let centerDepthMeters: Double
    let baselineDepthMeters: Double
    let heightAboveBaselineMeters: Double
    let sampleCount: Int
    let weakCandidateCount: Int
    let medianCandidateCount: Int
    let leftCandidateCount: Int
    let rightCandidateCount: Int
    let centroidPixel: PixelPoint
    let bounds: DepthCalibrationBounds
    let overlay: BrainDepthDetectionOverlaySnapshot
}

struct BrainDepthDetectionOverlaySnapshot: Equatable {
    let points: [HandJoint2D]
    let centroid: HandJoint2D
    let boundsMin: HandJoint2D
    let boundsMax: HandJoint2D
    let depthMapSize: PixelSize
    let candidateCount: Int
    let mapping: String

    static let empty = BrainDepthDetectionOverlaySnapshot(
        points: [],
        centroid: HandJoint2D(x: 0.5, y: 0.5),
        boundsMin: HandJoint2D(x: 0.5, y: 0.5),
        boundsMax: HandJoint2D(x: 0.5, y: 0.5),
        depthMapSize: PixelSize(w: 0, h: 0),
        candidateCount: 0,
        mapping: "none"
    )
}

enum DepthBrainCalibrationError: Error, CustomStringConvertible {
    case depthUnavailable
    case unsupportedDepthFormat
    case invalidDepthSize
    case noUsableBaselineSamples
    case baselineDepthSizeMismatch(expected: PixelSize, actual: PixelSize)
    case noBrainCandidate(sampleCount: Int)
    case invalidCameraIntrinsics

    var description: String {
        switch self {
        case .depthUnavailable:
            return "LiDAR depth is unavailable"
        case .unsupportedDepthFormat:
            return "Depth map is not Float32"
        case .invalidDepthSize:
            return "Depth map size is invalid"
        case .noUsableBaselineSamples:
            return "No usable empty-area depth samples"
        case .baselineDepthSizeMismatch(let expected, let actual):
            return "Depth size changed: expected \(expected.w)x\(expected.h), got \(actual.w)x\(actual.h)"
        case .noBrainCandidate(let sampleCount):
            return "No brain candidate found in depth difference (\(sampleCount) px)"
        case .invalidCameraIntrinsics:
            return "Camera intrinsics are invalid"
        }
    }
}

enum DepthBrainCalibrator {
    private static let minValidDepthMeters: Float = 0.15
    private static let maxValidDepthMeters: Float = 3.00
    private static let provisionalRadiusRatio: Double = 0.35
    private static let maxRadiusRatio: Double = 0.48
    private static let minCandidateSamples = 30

    static func makeBaseline(
        depthData: ARDepthData?,
        camera: ARCamera,
        workingRadiusMeters: Double = 0.50
    ) throws -> DepthCalibrationBaseline {
        guard let depthData else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            throw DepthBrainCalibrationError.unsupportedDepthFormat
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else {
            throw DepthBrainCalibrationError.invalidDepthSize
        }

        let centerX = Double(width - 1) / 2
        let centerY = Double(height - 1) / 2
        let provisionalRadius = Double(min(width, height)) * provisionalRadiusRatio
        let scaledIntrinsics = PointUnprojector.scaledIntrinsicsForDepth(
            camera: camera,
            depthMapSize: CGSize(width: width, height: height)
        )

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap = depthData.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceReader = makeConfidenceReader(
            confidenceMap: depthData.confidenceMap,
            depthWidth: width,
            depthHeight: height
        )

        var provisionalSamples: [Float] = []
        for y in 0..<height {
            for x in 0..<width where isInsideCircle(x: x, y: y, centerX: centerX, centerY: centerY, radius: provisionalRadius) {
                guard confidenceReader.isUsable(x, y) else { continue }
                let depth = readDepth(
                    depthBaseAddress: depthBaseAddress,
                    bytesPerRow: depthBytesPerRow,
                    x: x,
                    y: y
                )
                if isValidDepth(depth) {
                    provisionalSamples.append(depth)
                }
            }
        }

        guard let provisionalMedian = median(provisionalSamples) else {
            throw DepthBrainCalibrationError.noUsableBaselineSamples
        }

        let radiusPixels = calibratedWorkingRadiusPixels(
            workingRadiusMeters: workingRadiusMeters,
            referenceDepthMeters: Double(provisionalMedian),
            intrinsics: scaledIntrinsics,
            depthMapSize: PixelSize(w: width, h: height)
        )

        var depths = Array(repeating: Float.nan, count: width * height)
        var baselineSamples: [Float] = []
        for y in 0..<height {
            for x in 0..<width where isInsideCircle(x: x, y: y, centerX: centerX, centerY: centerY, radius: radiusPixels) {
                guard confidenceReader.isUsable(x, y) else { continue }
                let depth = readDepth(
                    depthBaseAddress: depthBaseAddress,
                    bytesPerRow: depthBytesPerRow,
                    x: x,
                    y: y
                )
                if isValidDepth(depth) {
                    depths[y * width + x] = depth
                    baselineSamples.append(depth)
                }
            }
        }

        guard let baselineMedian = median(baselineSamples) else {
            throw DepthBrainCalibrationError.noUsableBaselineSamples
        }

        return DepthCalibrationBaseline(
            depthMapSize: PixelSize(w: width, h: height),
            depths: depths,
            centerPixel: PixelPoint(x: Int(round(centerX)), y: Int(round(centerY))),
            workingRadiusPixels: radiusPixels,
            workingRadiusMeters: workingRadiusMeters,
            medianDepthMeters: Double(baselineMedian),
            sampleCount: baselineSamples.count
        )
    }

    static func estimateBrain(
        depthData: ARDepthData?,
        camera: ARCamera,
        baseline: DepthCalibrationBaseline,
        minHeightMeters: Double = 0.008
    ) throws -> DepthBrainCalibrationEstimate {
        guard let depthData else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            throw DepthBrainCalibrationError.unsupportedDepthFormat
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let actualSize = PixelSize(w: width, h: height)
        guard actualSize == baseline.depthMapSize else {
            throw DepthBrainCalibrationError.baselineDepthSizeMismatch(
                expected: baseline.depthMapSize,
                actual: actualSize
            )
        }

        let scaledIntrinsics = PointUnprojector.scaledIntrinsicsForDepth(
            camera: camera,
            depthMapSize: CGSize(width: width, height: height)
        )
        let fx = scaledIntrinsics.columns.0.x
        let fy = scaledIntrinsics.columns.1.y
        guard fx > 0, fy > 0 else {
            throw DepthBrainCalibrationError.invalidCameraIntrinsics
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap = depthData.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let minHeight = Float(minHeightMeters)
        let weakMinHeight = Float(0.004)
        let maxReasonableHeight: Float = 0.60

        var currentSamples: [Float] = []
        var baselineSamples: [Float] = []
        var xSamples: [Int] = []
        var ySamples: [Int] = []
        var candidatePixels: [PixelPoint] = []
        var weakCandidateCount = 0
        var medianCandidateCount = 0
        var leftCandidateCount = 0
        var rightCandidateCount = 0
        var sumX = 0.0
        var sumY = 0.0

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let baselineDepth = baseline.depths[index]
                guard isValidDepth(baselineDepth) else {
                    continue
                }

                let currentDepth = readDepth(
                    depthBaseAddress: depthBaseAddress,
                    bytesPerRow: depthBytesPerRow,
                    x: x,
                    y: y
                )
                guard isValidDepth(currentDepth) else { continue }

                let delta = baselineDepth - currentDepth
                let medianDelta = Float(baseline.medianDepthMeters) - currentDepth
                if max(delta, medianDelta) >= weakMinHeight,
                   max(delta, medianDelta) <= maxReasonableHeight {
                    weakCandidateCount += 1
                }
                if medianDelta >= minHeight,
                   medianDelta <= maxReasonableHeight {
                    medianCandidateCount += 1
                }

                let selectedDelta = max(delta, medianDelta)
                guard selectedDelta >= minHeight,
                      selectedDelta <= maxReasonableHeight else {
                    continue
                }

                currentSamples.append(currentDepth)
                baselineSamples.append(baselineDepth)
                xSamples.append(x)
                ySamples.append(y)
                candidatePixels.append(PixelPoint(x: x, y: y))
                if x < width / 2 {
                    leftCandidateCount += 1
                } else {
                    rightCandidateCount += 1
                }
                sumX += Double(x)
                sumY += Double(y)
            }
        }

        guard currentSamples.count >= minCandidateSamples,
              let objectMedianDepth = median(currentSamples),
              let baselineMedianDepth = median(baselineSamples) else {
            throw DepthBrainCalibrationError.noBrainCandidate(sampleCount: currentSamples.count)
        }

        let heightAboveBaseline = max(0.0, Double(baselineMedianDepth - objectMedianDepth))
        let centerDepth = min(
            Double(objectMedianDepth) + heightAboveBaseline * 0.5,
            Double(baselineMedianDepth)
        )
        let centroidX = sumX / Double(currentSamples.count)
        let centroidY = sumY / Double(currentSamples.count)
        let bounds = robustBounds(xSamples: xSamples, ySamples: ySamples)
        let overlay = makeOverlay(
            candidatePixels: candidatePixels,
            centroidX: centroidX,
            centroidY: centroidY,
            bounds: bounds,
            depthMapSize: actualSize
        )
        let cameraSpaceCenter = PointUnprojector.unprojectPoint(
            pixelX: Float(centroidX),
            pixelY: Float(centroidY),
            depthMeters: Float(centerDepth),
            intrinsics: scaledIntrinsics
        )
        let worldCenter = camera.transform * SIMD4<Float>(
            cameraSpaceCenter.x,
            cameraSpaceCenter.y,
            cameraSpaceCenter.z,
            1
        )

        let topDepth = Double(objectMedianDepth)
        let widthMeters = Double(Float(bounds.widthPixels) * Float(topDepth) / fx)
        let depthMeters = Double(Float(bounds.heightPixels) * Float(topDepth) / fy)

        return DepthBrainCalibrationEstimate(
            centerWorld: HandJoint3D(
                x: Double(worldCenter.x),
                y: Double(worldCenter.y),
                z: Double(worldCenter.z)
            ),
            widthMeters: widthMeters,
            depthMeters: depthMeters,
            heightMeters: heightAboveBaseline,
            topSurfaceDepthMeters: topDepth,
            centerDepthMeters: centerDepth,
            baselineDepthMeters: Double(baselineMedianDepth),
            heightAboveBaselineMeters: heightAboveBaseline,
            sampleCount: currentSamples.count,
            weakCandidateCount: weakCandidateCount,
            medianCandidateCount: medianCandidateCount,
            leftCandidateCount: leftCandidateCount,
            rightCandidateCount: rightCandidateCount,
            centroidPixel: PixelPoint(x: Int(round(centroidX)), y: Int(round(centroidY))),
            bounds: bounds,
            overlay: overlay
        )
    }

    private static func calibratedWorkingRadiusPixels(
        workingRadiusMeters: Double,
        referenceDepthMeters: Double,
        intrinsics: simd_float3x3,
        depthMapSize: PixelSize
    ) -> Double {
        let minFocalLength = Double(min(intrinsics.columns.0.x, intrinsics.columns.1.y))
        let minDimension = Double(min(depthMapSize.w, depthMapSize.h))
        guard minFocalLength > 0,
              referenceDepthMeters > 0 else {
            return minDimension * provisionalRadiusRatio
        }

        let radius = minFocalLength * workingRadiusMeters / referenceDepthMeters
        return clamp(radius, min: 8, max: minDimension * maxRadiusRatio)
    }

    private static func makeConfidenceReader(
        confidenceMap: CVPixelBuffer?,
        depthWidth: Int,
        depthHeight: Int
    ) -> DepthConfidenceReader {
        guard let confidenceMap,
              CVPixelBufferGetWidth(confidenceMap) == depthWidth,
              CVPixelBufferGetHeight(confidenceMap) == depthHeight,
              let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return DepthConfidenceReader(baseAddress: nil, bytesPerRow: 0)
        }

        return DepthConfidenceReader(
            baseAddress: baseAddress,
            bytesPerRow: CVPixelBufferGetBytesPerRow(confidenceMap)
        )
    }

    private static func readDepth(
        depthBaseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> Float {
        let row = depthBaseAddress.advanced(by: y * bytesPerRow)
        return row.assumingMemoryBound(to: Float32.self)[x]
    }

    private static func isValidDepth(_ value: Float) -> Bool {
        value.isFinite && value >= minValidDepthMeters && value <= maxValidDepthMeters
    }

    private static func isInsideCircle(
        x: Int,
        y: Int,
        centerX: Double,
        centerY: Double,
        radius: Double
    ) -> Bool {
        let dx = Double(x) - centerX
        let dy = Double(y) - centerY
        return dx * dx + dy * dy <= radius * radius
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func robustBounds(xSamples: [Int], ySamples: [Int]) -> DepthCalibrationBounds {
        let minX = percentile(xSamples, ratio: 0.02) ?? xSamples.min() ?? 0
        let maxX = percentile(xSamples, ratio: 0.98) ?? xSamples.max() ?? minX
        let minY = percentile(ySamples, ratio: 0.02) ?? ySamples.min() ?? 0
        let maxY = percentile(ySamples, ratio: 0.98) ?? ySamples.max() ?? minY

        return DepthCalibrationBounds(
            minX: min(minX, maxX),
            minY: min(minY, maxY),
            maxX: max(minX, maxX),
            maxY: max(minY, maxY)
        )
    }

    private static func percentile(_ values: [Int], ratio: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clampedRatio = clamp(ratio, min: 0, max: 1)
        let index = Int(round(clampedRatio * Double(sorted.count - 1)))
        return sorted[index]
    }

    private static func makeOverlay(
        candidatePixels: [PixelPoint],
        centroidX: Double,
        centroidY: Double,
        bounds: DepthCalibrationBounds,
        depthMapSize: PixelSize
    ) -> BrainDepthDetectionOverlaySnapshot {
        let maxPointCount = 900
        let step = max(1, candidatePixels.count / maxPointCount)
        let points = candidatePixels.enumerated().compactMap { index, pixel -> HandJoint2D? in
            guard index % step == 0 else { return nil }
            return depthPixelToDisplayPoint(
                x: Double(pixel.x),
                y: Double(pixel.y),
                depthMapSize: depthMapSize
            )
        }

        return BrainDepthDetectionOverlaySnapshot(
            points: points,
            centroid: depthPixelToDisplayPoint(
                x: centroidX,
                y: centroidY,
                depthMapSize: depthMapSize
            ),
            boundsMin: depthPixelToDisplayPoint(
                x: Double(bounds.minX),
                y: Double(bounds.minY),
                depthMapSize: depthMapSize
            ),
            boundsMax: depthPixelToDisplayPoint(
                x: Double(bounds.maxX),
                y: Double(bounds.maxY),
                depthMapSize: depthMapSize
            ),
            depthMapSize: depthMapSize,
            candidateCount: candidatePixels.count,
            mapping: "portrait_back_raw_to_display"
        )
    }

    private static func depthPixelToDisplayPoint(
        x: Double,
        y: Double,
        depthMapSize: PixelSize
    ) -> HandJoint2D {
        let safeWidth = max(1, depthMapSize.w - 1)
        let safeHeight = max(1, depthMapSize.h - 1)
        let rawX = clamp(x / Double(safeWidth), min: 0, max: 1)
        let rawY = clamp(y / Double(safeHeight), min: 0, max: 1)

        // ARKit depth maps arrive in the captured image's raw orientation. In the
        // current portrait/back-camera setup, this is the inverse of
        // DepthSampler.visionPointToRawImageNormalizedPortraitBack(_:).
        return HandJoint2D(
            x: 1.0 - rawY,
            y: rawX
        )
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

private struct DepthConfidenceReader {
    let baseAddress: UnsafeMutableRawPointer?
    let bytesPerRow: Int

    func isUsable(_ x: Int, _ y: Int) -> Bool {
        guard let baseAddress else {
            return true
        }

        let row = baseAddress.advanced(by: y * bytesPerRow)
        return row.assumingMemoryBound(to: UInt8.self)[x] > 0
    }
}
