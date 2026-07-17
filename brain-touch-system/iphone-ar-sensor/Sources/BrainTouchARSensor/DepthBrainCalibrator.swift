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
    let cameraTransform: simd_float4x4
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
    let rawDepthCount: Int
    let baselineValidCount: Int
    let lowRaisedCount: Int
    let weakCandidateCount: Int
    let candidateCount: Int
    let maxRaisedHeightMeters: Double
    let mapping: String

    static let empty = BrainDepthDetectionOverlaySnapshot(
        points: [],
        centroid: HandJoint2D(x: 0.5, y: 0.5),
        boundsMin: HandJoint2D(x: 0.5, y: 0.5),
        boundsMax: HandJoint2D(x: 0.5, y: 0.5),
        depthMapSize: PixelSize(w: 0, h: 0),
        rawDepthCount: 0,
        baselineValidCount: 0,
        lowRaisedCount: 0,
        weakCandidateCount: 0,
        candidateCount: 0,
        maxRaisedHeightMeters: 0,
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
    case cameraMovedDuringCapture
    case implausibleBrainSize(width: Double, depth: Double, height: Double)

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
        case .cameraMovedDuringCapture:
            return "iPhone moved during or after baseline; capture baseline again"
        case .implausibleBrainSize(let width, let depth, let height):
            return String(format: "Detected object size is not brain-like: %.2f x %.2f x %.2f m", width, depth, height)
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

        let confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBaseAddress = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceBytesPerRow = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
        let confidenceMatches = confidenceMap.map {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height
        } ?? false
        var provisionalSamples: [Float] = []
        for y in 0..<height {
            for x in 0..<width where isInsideCircle(x: x, y: y, centerX: centerX, centerY: centerY, radius: provisionalRadius) {
                guard isConfidenceUsable(
                    baseAddress: confidenceBaseAddress,
                    bytesPerRow: confidenceBytesPerRow,
                    x: x,
                    y: y,
                    required: confidenceMatches
                ) else { continue }
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
                guard isConfidenceUsable(
                    baseAddress: confidenceBaseAddress,
                    bytesPerRow: confidenceBytesPerRow,
                    x: x,
                    y: y,
                    required: confidenceMatches
                ) else { continue }
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
            sampleCount: baselineSamples.count,
            cameraTransform: camera.transform
        )
    }

    static func mergeBaselines(_ baselines: [DepthCalibrationBaseline]) throws -> DepthCalibrationBaseline {
        guard let first = baselines.first else {
            throw DepthBrainCalibrationError.noUsableBaselineSamples
        }
        for baseline in baselines {
            guard baseline.depthMapSize == first.depthMapSize else {
                throw DepthBrainCalibrationError.baselineDepthSizeMismatch(
                    expected: first.depthMapSize,
                    actual: baseline.depthMapSize
                )
            }
            let firstPosition = first.cameraTransform.columns.3
            let position = baseline.cameraTransform.columns.3
            let translation = simd_distance(
                SIMD3<Float>(firstPosition.x, firstPosition.y, firstPosition.z),
                SIMD3<Float>(position.x, position.y, position.z)
            )
            let firstForward = -SIMD3<Float>(
                first.cameraTransform.columns.2.x,
                first.cameraTransform.columns.2.y,
                first.cameraTransform.columns.2.z
            )
            let forward = -SIMD3<Float>(
                baseline.cameraTransform.columns.2.x,
                baseline.cameraTransform.columns.2.y,
                baseline.cameraTransform.columns.2.z
            )
            if translation > 0.01 || simd_dot(simd_normalize(firstForward), simd_normalize(forward)) < 0.999 {
                throw DepthBrainCalibrationError.cameraMovedDuringCapture
            }
        }

        var mergedDepths = Array(repeating: Float.nan, count: first.depths.count)
        var valid: [Float] = []
        for index in mergedDepths.indices {
            let values = baselines.compactMap { baseline -> Float? in
                let value = baseline.depths[index]
                return value.isFinite ? value : nil
            }
            if values.count >= max(3, baselines.count / 2),
               let value = median(values) {
                mergedDepths[index] = value
                valid.append(value)
            }
        }
        guard let mergedMedian = median(valid) else {
            throw DepthBrainCalibrationError.noUsableBaselineSamples
        }
        return DepthCalibrationBaseline(
            depthMapSize: first.depthMapSize,
            depths: mergedDepths,
            centerPixel: first.centerPixel,
            workingRadiusPixels: first.workingRadiusPixels,
            workingRadiusMeters: first.workingRadiusMeters,
            medianDepthMeters: Double(mergedMedian),
            sampleCount: valid.count,
            cameraTransform: first.cameraTransform
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
        guard cameraPoseMatchesBaseline(camera.transform, baseline.cameraTransform) else {
            throw DepthBrainCalibrationError.cameraMovedDuringCapture
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

        let confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBaseAddress = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceBytesPerRow = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
        let confidenceMatches = confidenceMap.map {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height
        } ?? false
        let minHeight = Float(minHeightMeters)
        let weakMinHeight = Float(0.004)
        let maxReasonableHeight: Float = 0.60

        let sideExpansionMinHeight: Float = 0.002
        var currentDepths = Array(repeating: Float.nan, count: width * height)
        var strongPixels: [PixelPoint] = []
        var expandableMask = Array(repeating: false, count: width * height)
        var baselineValidCount = 0
        var rawDepthCount = 0
        var lowRaisedCount = 0
        var weakCandidateCount = 0
        var medianCandidateCount = 0
        var maxRaisedHeight: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                guard isConfidenceUsable(
                    baseAddress: confidenceBaseAddress,
                    bytesPerRow: confidenceBytesPerRow,
                    x: x,
                    y: y,
                    required: confidenceMatches
                ) else { continue }
                let index = y * width + x
                let baselineDepth = baseline.depths[index]
                guard isValidDepth(baselineDepth) else {
                    continue
                }
                baselineValidCount += 1

                let currentDepth = readDepth(
                    depthBaseAddress: depthBaseAddress,
                    bytesPerRow: depthBytesPerRow,
                    x: x,
                    y: y
                )
                guard isValidDepth(currentDepth) else { continue }
                currentDepths[index] = currentDepth
                rawDepthCount += 1

                let delta = baselineDepth - currentDepth
                let medianDelta = Float(baseline.medianDepthMeters) - currentDepth
                // Static foreground objects can be closer than the scene median
                // without moving. Only the same-pixel delta marks a new object.
                let selectedDelta = delta
                if selectedDelta > 0.001,
                   selectedDelta <= maxReasonableHeight {
                    lowRaisedCount += 1
                    maxRaisedHeight = max(maxRaisedHeight, selectedDelta)
                }
                if selectedDelta >= sideExpansionMinHeight,
                   selectedDelta <= maxReasonableHeight {
                    expandableMask[index] = true
                }
                if selectedDelta >= weakMinHeight,
                   selectedDelta <= maxReasonableHeight {
                    weakCandidateCount += 1
                }
                if medianDelta >= minHeight,
                   medianDelta <= maxReasonableHeight {
                    medianCandidateCount += 1
                }

                guard selectedDelta >= minHeight,
                      selectedDelta <= maxReasonableHeight else {
                    continue
                }

                strongPixels.append(PixelPoint(x: x, y: y))
            }
        }

        guard strongPixels.count >= minCandidateSamples else {
            throw DepthBrainCalibrationError.noBrainCandidate(sampleCount: strongPixels.count)
        }

        let centerPixel = PixelPoint(
            x: Int(round(Double(width - 1) / 2)),
            y: Int(round(Double(height - 1) / 2))
        )
        let centeredStrongPixels = connectedSeedPixelsBestMatchingBrain(
            seeds: strongPixels,
            depthMapSize: actualSize,
            centerPixel: centerPixel
        )
        guard centeredStrongPixels.count >= minCandidateSamples else {
            throw DepthBrainCalibrationError.noBrainCandidate(sampleCount: centeredStrongPixels.count)
        }
        let strongBounds = robustBounds(
            xSamples: centeredStrongPixels.map(\.x),
            ySamples: centeredStrongPixels.map(\.y)
        )
        let allowedBounds = expandedBounds(
            from: strongBounds,
            depthMapSize: actualSize
        )
        let denoisedExpandableMask = denoiseMask(
            expandableMask,
            depthMapSize: actualSize,
            minNeighborCount: 3
        )
        let expandedCandidatePixels = connectedObjectPixels(
            seeds: centeredStrongPixels,
            expandableMask: denoisedExpandableMask,
            depthMapSize: actualSize,
            allowedBounds: allowedBounds
        )
        let candidatePixels = denoisePixels(
            expandedCandidatePixels,
            depthMapSize: actualSize,
            minNeighborCount: 3
        )

        var currentSamples: [Float] = []
        var baselineSamples: [Float] = []
        var xSamples: [Int] = []
        var ySamples: [Int] = []
        var leftCandidateCount = 0
        var rightCandidateCount = 0
        var sumX = 0.0
        var sumY = 0.0
        for pixel in candidatePixels {
            let index = pixel.y * width + pixel.x
            let currentDepth = currentDepths[index]
            let baselineDepth = baseline.depths[index]
            guard isValidDepth(currentDepth), isValidDepth(baselineDepth) else {
                continue
            }

            currentSamples.append(currentDepth)
            baselineSamples.append(baselineDepth)
            xSamples.append(pixel.x)
            ySamples.append(pixel.y)
            if pixel.x < width / 2 {
                leftCandidateCount += 1
            } else {
                rightCandidateCount += 1
            }
            sumX += Double(pixel.x)
            sumY += Double(pixel.y)
        }

        let strongCurrentSamples = centeredStrongPixels.compactMap { pixel -> Float? in
            let depth = currentDepths[pixel.y * width + pixel.x]
            return isValidDepth(depth) ? depth : nil
        }

        guard currentSamples.count >= minCandidateSamples,
              let objectMedianDepth = median(currentSamples),
              let topMedianDepth = median(strongCurrentSamples),
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
            depthMapSize: actualSize,
            rawDepthCount: rawDepthCount,
            baselineValidCount: baselineValidCount,
            lowRaisedCount: lowRaisedCount,
            weakCandidateCount: weakCandidateCount,
            maxRaisedHeight: maxRaisedHeight
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

        let topDepth = Double(topMedianDepth)
        // Raw portrait/back-camera depth Y maps to display X, so the physical
        // model width comes from the raw Y span and depth from the raw X span.
        let widthMeters = Double(Float(bounds.heightPixels) * Float(topDepth) / fy)
        let depthMeters = Double(Float(bounds.widthPixels) * Float(topDepth) / fx)
        guard (0.08...0.35).contains(widthMeters),
              (0.08...0.40).contains(depthMeters),
              (0.025...0.25).contains(heightAboveBaseline) else {
            throw DepthBrainCalibrationError.implausibleBrainSize(
                width: widthMeters,
                depth: depthMeters,
                height: heightAboveBaseline
            )
        }

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

    static func mergeEstimates(_ estimates: [DepthBrainCalibrationEstimate]) throws -> DepthBrainCalibrationEstimate {
        guard let first = estimates.first else {
            throw DepthBrainCalibrationError.noBrainCandidate(sampleCount: 0)
        }

        let centerX = median(estimates.map { Float($0.centerWorld.x) }).map(Double.init) ?? first.centerWorld.x
        let centerY = median(estimates.map { Float($0.centerWorld.y) }).map(Double.init) ?? first.centerWorld.y
        let centerZ = median(estimates.map { Float($0.centerWorld.z) }).map(Double.init) ?? first.centerWorld.z
        let width = median(estimates.map { Float($0.widthMeters) }).map(Double.init) ?? first.widthMeters
        let depth = median(estimates.map { Float($0.depthMeters) }).map(Double.init) ?? first.depthMeters
        let height = median(estimates.map { Float($0.heightMeters) }).map(Double.init) ?? first.heightMeters
        let representative = estimates.min { lhs, rhs in
            estimateDistance(lhs, width: width, depth: depth, height: height) <
                estimateDistance(rhs, width: width, depth: depth, height: height)
        } ?? first

        return DepthBrainCalibrationEstimate(
            centerWorld: HandJoint3D(x: centerX, y: centerY, z: centerZ),
            widthMeters: width,
            depthMeters: depth,
            heightMeters: height,
            topSurfaceDepthMeters: representative.topSurfaceDepthMeters,
            centerDepthMeters: representative.centerDepthMeters,
            baselineDepthMeters: representative.baselineDepthMeters,
            heightAboveBaselineMeters: height,
            sampleCount: representative.sampleCount,
            weakCandidateCount: representative.weakCandidateCount,
            medianCandidateCount: representative.medianCandidateCount,
            leftCandidateCount: representative.leftCandidateCount,
            rightCandidateCount: representative.rightCandidateCount,
            centroidPixel: representative.centroidPixel,
            bounds: representative.bounds,
            overlay: representative.overlay
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

    private static func readDepth(
        depthBaseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> Float {
        let row = depthBaseAddress.advanced(by: y * bytesPerRow)
        return row.assumingMemoryBound(to: Float32.self)[x]
    }

    private static func isConfidenceUsable(
        baseAddress: UnsafeMutableRawPointer?,
        bytesPerRow: Int,
        x: Int,
        y: Int,
        required: Bool
    ) -> Bool {
        guard required else { return true }
        guard let baseAddress else { return false }
        let row = baseAddress.advanced(by: y * bytesPerRow)
        return row.assumingMemoryBound(to: UInt8.self)[x] >= 1
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

    private static func expandedBounds(
        from bounds: DepthCalibrationBounds,
        depthMapSize: PixelSize
    ) -> DepthCalibrationBounds {
        let xMargin = max(8, Int(round(Double(bounds.widthPixels) * 0.45)))
        let yMargin = max(8, Int(round(Double(bounds.heightPixels) * 0.45)))
        return DepthCalibrationBounds(
            minX: max(0, bounds.minX - xMargin),
            minY: max(0, bounds.minY - yMargin),
            maxX: min(depthMapSize.w - 1, bounds.maxX + xMargin),
            maxY: min(depthMapSize.h - 1, bounds.maxY + yMargin)
        )
    }

    private static func connectedSeedPixelsBestMatchingBrain(
        seeds: [PixelPoint],
        depthMapSize: PixelSize,
        centerPixel: PixelPoint
    ) -> [PixelPoint] {
        guard !seeds.isEmpty else { return [] }

        let width = depthMapSize.w
        let height = depthMapSize.h
        var seedMask = Array(repeating: false, count: width * height)
        for seed in seeds where seed.x >= 0 && seed.x < width && seed.y >= 0 && seed.y < height {
            seedMask[seed.y * width + seed.x] = true
        }

        var visited = Array(repeating: false, count: width * height)
        var bestComponent: [PixelPoint] = []
        var bestScore = Double.greatestFiniteMagnitude
        let distanceScale = Double(max(1, min(width, height)))

        for seed in seeds {
            let seedIndex = seed.y * width + seed.x
            guard seedMask.indices.contains(seedIndex),
                  seedMask[seedIndex],
                  !visited[seedIndex] else {
                continue
            }

            let component = floodFillComponent(
                start: seed,
                mask: seedMask,
                visited: &visited,
                depthMapSize: depthMapSize
            )
            guard component.count >= minCandidateSamples else {
                continue
            }

            let centroid = centroid(of: component)
            let centerDistance = sqrt(squaredDistance(
                x0: centroid.x,
                y0: centroid.y,
                x1: Double(centerPixel.x),
                y1: Double(centerPixel.y)
            )) / distanceScale
            let bounds = robustBounds(
                xSamples: component.map(\.x),
                ySamples: component.map(\.y)
            )
            let shortSpan = max(1, min(bounds.widthPixels, bounds.heightPixels))
            let longSpan = max(bounds.widthPixels, bounds.heightPixels)
            let aspectRatio = Double(longSpan) / Double(shortSpan)

            // Shelf edges and camera-motion bands are typically long, thin
            // components. A physical brain can be off-center, but its depth
            // silhouette should remain compact in the raw depth image.
            guard aspectRatio <= 3.25,
                  shortSpan >= 5 else {
                continue
            }

            let boundsArea = max(1, bounds.widthPixels * bounds.heightPixels)
            let fillRatio = Double(component.count) / Double(boundsArea)
            let aspectPenalty = abs(log(aspectRatio)) * 0.42
            let sparsePenalty = max(0, 0.18 - fillRatio) * 1.8
            let sizeReward = min(0.35, log1p(Double(component.count)) * 0.045)
            let score = centerDistance + aspectPenalty + sparsePenalty - sizeReward

            if score < bestScore {
                bestScore = score
                bestComponent = component
            }
        }

        return bestComponent
    }

    private static func cameraPoseMatchesBaseline(
        _ current: simd_float4x4,
        _ baseline: simd_float4x4
    ) -> Bool {
        let currentPosition = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        let baselinePosition = SIMD3<Float>(baseline.columns.3.x, baseline.columns.3.y, baseline.columns.3.z)
        guard simd_distance(currentPosition, baselinePosition) <= 0.025 else {
            return false
        }

        let currentForward = simd_normalize(-SIMD3<Float>(
            current.columns.2.x,
            current.columns.2.y,
            current.columns.2.z
        ))
        let baselineForward = simd_normalize(-SIMD3<Float>(
            baseline.columns.2.x,
            baseline.columns.2.y,
            baseline.columns.2.z
        ))
        return simd_dot(currentForward, baselineForward) >= 0.9994
    }

    private static func estimateDistance(
        _ estimate: DepthBrainCalibrationEstimate,
        width: Double,
        depth: Double,
        height: Double
    ) -> Double {
        abs(estimate.widthMeters - width) +
            abs(estimate.depthMeters - depth) +
            abs(estimate.heightMeters - height)
    }

    private static func connectedObjectPixels(
        seeds: [PixelPoint],
        expandableMask: [Bool],
        depthMapSize: PixelSize,
        allowedBounds: DepthCalibrationBounds
    ) -> [PixelPoint] {
        guard !seeds.isEmpty else { return [] }

        let width = depthMapSize.w
        let height = depthMapSize.h
        var visited = Array(repeating: false, count: width * height)
        var queue: [PixelPoint] = []
        queue.reserveCapacity(seeds.count)

        for seed in seeds where isInside(seed, bounds: allowedBounds) {
            let index = seed.y * width + seed.x
            guard expandableMask.indices.contains(index),
                  expandableMask[index],
                  !visited[index] else {
                continue
            }

            visited[index] = true
            queue.append(seed)
        }

        var head = 0
        while head < queue.count {
            let pixel = queue[head]
            head += 1

            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }

                    let next = PixelPoint(x: pixel.x + dx, y: pixel.y + dy)
                    guard next.x >= 0,
                          next.x < width,
                          next.y >= 0,
                          next.y < height,
                          isInside(next, bounds: allowedBounds) else {
                        continue
                    }

                    let index = next.y * width + next.x
                    guard expandableMask[index], !visited[index] else {
                        continue
                    }

                    visited[index] = true
                    queue.append(next)
                }
            }
        }

        return queue
    }

    private static func denoiseMask(
        _ mask: [Bool],
        depthMapSize: PixelSize,
        minNeighborCount: Int
    ) -> [Bool] {
        let width = depthMapSize.w
        let height = depthMapSize.h
        guard mask.count == width * height else { return mask }

        var result = mask
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask[index] else { continue }
                if neighborCount(x: x, y: y, mask: mask, depthMapSize: depthMapSize) < minNeighborCount {
                    result[index] = false
                }
            }
        }

        return result
    }

    private static func denoisePixels(
        _ pixels: [PixelPoint],
        depthMapSize: PixelSize,
        minNeighborCount: Int
    ) -> [PixelPoint] {
        guard pixels.count >= minCandidateSamples else { return pixels }

        let width = depthMapSize.w
        let height = depthMapSize.h
        var mask = Array(repeating: false, count: width * height)
        for pixel in pixels where pixel.x >= 0 && pixel.x < width && pixel.y >= 0 && pixel.y < height {
            mask[pixel.y * width + pixel.x] = true
        }

        let filtered = pixels.filter { pixel in
            neighborCount(x: pixel.x, y: pixel.y, mask: mask, depthMapSize: depthMapSize) >= minNeighborCount
        }
        return filtered.count >= minCandidateSamples ? filtered : pixels
    }

    private static func neighborCount(
        x: Int,
        y: Int,
        mask: [Bool],
        depthMapSize: PixelSize
    ) -> Int {
        let width = depthMapSize.w
        let height = depthMapSize.h
        var count = 0
        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 { continue }

                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else {
                    continue
                }

                if mask[ny * width + nx] {
                    count += 1
                }
            }
        }
        return count
    }

    private static func floodFillComponent(
        start: PixelPoint,
        mask: [Bool],
        visited: inout [Bool],
        depthMapSize: PixelSize
    ) -> [PixelPoint] {
        let width = depthMapSize.w
        let height = depthMapSize.h
        var component: [PixelPoint] = []
        var queue = [start]
        visited[start.y * width + start.x] = true

        var head = 0
        while head < queue.count {
            let pixel = queue[head]
            head += 1
            component.append(pixel)

            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }

                    let next = PixelPoint(x: pixel.x + dx, y: pixel.y + dy)
                    guard next.x >= 0,
                          next.x < width,
                          next.y >= 0,
                          next.y < height else {
                        continue
                    }

                    let index = next.y * width + next.x
                    guard mask[index], !visited[index] else {
                        continue
                    }

                    visited[index] = true
                    queue.append(next)
                }
            }
        }

        return component
    }

    private static func centroid(of pixels: [PixelPoint]) -> (x: Double, y: Double) {
        guard !pixels.isEmpty else { return (0, 0) }

        let sum = pixels.reduce((x: 0.0, y: 0.0)) { partial, pixel in
            (
                x: partial.x + Double(pixel.x),
                y: partial.y + Double(pixel.y)
            )
        }
        return (
            x: sum.x / Double(pixels.count),
            y: sum.y / Double(pixels.count)
        )
    }

    private static func squaredDistance(
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double
    ) -> Double {
        let dx = x0 - x1
        let dy = y0 - y1
        return dx * dx + dy * dy
    }

    private static func isInside(_ pixel: PixelPoint, bounds: DepthCalibrationBounds) -> Bool {
        pixel.x >= bounds.minX &&
            pixel.x <= bounds.maxX &&
            pixel.y >= bounds.minY &&
            pixel.y <= bounds.maxY
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
        depthMapSize: PixelSize,
        rawDepthCount: Int,
        baselineValidCount: Int,
        lowRaisedCount: Int,
        weakCandidateCount: Int,
        maxRaisedHeight: Float
    ) -> BrainDepthDetectionOverlaySnapshot {
        let points = displayPoints(from: candidatePixels, maxPointCount: 500, depthMapSize: depthMapSize)

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
            rawDepthCount: rawDepthCount,
            baselineValidCount: baselineValidCount,
            lowRaisedCount: lowRaisedCount,
            weakCandidateCount: weakCandidateCount,
            candidateCount: candidatePixels.count,
            maxRaisedHeightMeters: Double(maxRaisedHeight),
            mapping: "portrait_back_raw_to_display"
        )
    }

    private static func displayPoints(
        from pixels: [PixelPoint],
        maxPointCount: Int,
        depthMapSize: PixelSize
    ) -> [HandJoint2D] {
        guard !pixels.isEmpty else { return [] }
        let step = max(1, pixels.count / maxPointCount)
        return pixels.enumerated().compactMap { index, pixel -> HandJoint2D? in
            guard index % step == 0 else { return nil }
            return depthPixelToDisplayPoint(
                x: Double(pixel.x),
                y: Double(pixel.y),
                depthMapSize: depthMapSize
            )
        }
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
