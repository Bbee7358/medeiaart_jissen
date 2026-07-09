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

struct DepthDeltaOverlayPoint: Equatable {
    let point: HandJoint2D
    let heightMeters: Double
}

struct BrainDepthDetectionOverlaySnapshot: Equatable {
    let rawDepthPoints: [HandJoint2D]
    let raisedHeatPoints: [DepthDeltaOverlayPoint]
    let weakPoints: [HandJoint2D]
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
        rawDepthPoints: [],
        raisedHeatPoints: [],
        weakPoints: [],
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
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        var provisionalSamples: [Float] = []
        for y in 0..<height {
            for x in 0..<width where isInsideCircle(x: x, y: y, centerX: centerX, centerY: centerY, radius: provisionalRadius) {
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
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw DepthBrainCalibrationError.depthUnavailable
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let minHeight = Float(minHeightMeters)
        let weakMinHeight = Float(0.004)
        let maxReasonableHeight: Float = 0.60

        let sideExpansionMinHeight: Float = 0.002
        var currentDepths = Array(repeating: Float.nan, count: width * height)
        var strongPixels: [PixelPoint] = []
        var expandableMask = Array(repeating: false, count: width * height)
        var rawDepthPixels: [PixelPoint] = []
        var raisedPixels: [(pixel: PixelPoint, height: Float)] = []
        var weakPixels: [PixelPoint] = []
        var baselineValidCount = 0
        var rawDepthCount = 0
        var lowRaisedCount = 0
        var weakCandidateCount = 0
        var medianCandidateCount = 0

        for y in 0..<height {
            for x in 0..<width {
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
                rawDepthPixels.append(PixelPoint(x: x, y: y))

                let delta = baselineDepth - currentDepth
                let medianDelta = Float(baseline.medianDepthMeters) - currentDepth
                let selectedDelta = max(delta, medianDelta)
                if selectedDelta > 0.001,
                   selectedDelta <= maxReasonableHeight {
                    lowRaisedCount += 1
                    raisedPixels.append((pixel: PixelPoint(x: x, y: y), height: selectedDelta))
                }
                if selectedDelta >= sideExpansionMinHeight,
                   selectedDelta <= maxReasonableHeight {
                    expandableMask[index] = true
                }
                if selectedDelta >= weakMinHeight,
                   selectedDelta <= maxReasonableHeight {
                    weakCandidateCount += 1
                    weakPixels.append(PixelPoint(x: x, y: y))
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
        let centeredStrongPixels = connectedSeedPixelsClosestToCenter(
            seeds: strongPixels,
            depthMapSize: actualSize,
            centerPixel: centerPixel
        )
        let strongBounds = robustBounds(
            xSamples: centeredStrongPixels.map(\.x),
            ySamples: centeredStrongPixels.map(\.y)
        )
        let allowedBounds = expandedBounds(
            from: strongBounds,
            depthMapSize: actualSize
        )
        let candidatePixels = connectedObjectPixels(
            seeds: centeredStrongPixels,
            expandableMask: expandableMask,
            depthMapSize: actualSize,
            allowedBounds: allowedBounds
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
            rawDepthPixels: rawDepthPixels,
            raisedPixels: raisedPixels,
            weakPixels: weakPixels,
            candidatePixels: candidatePixels,
            centroidX: centroidX,
            centroidY: centroidY,
            bounds: bounds,
            depthMapSize: actualSize,
            rawDepthCount: rawDepthCount,
            baselineValidCount: baselineValidCount,
            lowRaisedCount: lowRaisedCount,
            weakCandidateCount: weakCandidateCount
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

    private static func expandedBounds(
        from bounds: DepthCalibrationBounds,
        depthMapSize: PixelSize
    ) -> DepthCalibrationBounds {
        let xMargin = max(12, Int(round(Double(bounds.widthPixels) * 0.85)))
        let yMargin = max(12, Int(round(Double(bounds.heightPixels) * 0.85)))
        return DepthCalibrationBounds(
            minX: max(0, bounds.minX - xMargin),
            minY: max(0, bounds.minY - yMargin),
            maxX: min(depthMapSize.w - 1, bounds.maxX + xMargin),
            maxY: min(depthMapSize.h - 1, bounds.maxY + yMargin)
        )
    }

    private static func connectedSeedPixelsClosestToCenter(
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
        var bestDistance = Double.greatestFiniteMagnitude
        var bestCount = 0

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
            let distance = squaredDistance(
                x0: centroid.x,
                y0: centroid.y,
                x1: Double(centerPixel.x),
                y1: Double(centerPixel.y)
            )
            if distance < bestDistance ||
                (distance == bestDistance && component.count > bestCount) {
                bestDistance = distance
                bestCount = component.count
                bestComponent = component
            }
        }

        return bestComponent.isEmpty ? seeds : bestComponent
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
        rawDepthPixels: [PixelPoint],
        raisedPixels: [(pixel: PixelPoint, height: Float)],
        weakPixels: [PixelPoint],
        candidatePixels: [PixelPoint],
        centroidX: Double,
        centroidY: Double,
        bounds: DepthCalibrationBounds,
        depthMapSize: PixelSize,
        rawDepthCount: Int,
        baselineValidCount: Int,
        lowRaisedCount: Int,
        weakCandidateCount: Int
    ) -> BrainDepthDetectionOverlaySnapshot {
        let rawPoints = displayPoints(from: rawDepthPixels, maxPointCount: 900, depthMapSize: depthMapSize)
        let raisedHeatPoints = heatPoints(from: raisedPixels, maxPointCount: 1200, depthMapSize: depthMapSize)
        let weakPoints = displayPoints(from: weakPixels, maxPointCount: 900, depthMapSize: depthMapSize)
        let points = displayPoints(from: candidatePixels, maxPointCount: 900, depthMapSize: depthMapSize)
        let maxRaisedHeight = raisedPixels.map(\.height).max() ?? 0

        return BrainDepthDetectionOverlaySnapshot(
            rawDepthPoints: rawPoints,
            raisedHeatPoints: raisedHeatPoints,
            weakPoints: weakPoints,
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

    private static func heatPoints(
        from pixels: [(pixel: PixelPoint, height: Float)],
        maxPointCount: Int,
        depthMapSize: PixelSize
    ) -> [DepthDeltaOverlayPoint] {
        guard !pixels.isEmpty else { return [] }
        let step = max(1, pixels.count / maxPointCount)
        return pixels.enumerated().compactMap { index, sample -> DepthDeltaOverlayPoint? in
            guard index % step == 0 else { return nil }
            return DepthDeltaOverlayPoint(
                point: depthPixelToDisplayPoint(
                    x: Double(sample.pixel.x),
                    y: Double(sample.pixel.y),
                    depthMapSize: depthMapSize
                ),
                heightMeters: Double(sample.height)
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
