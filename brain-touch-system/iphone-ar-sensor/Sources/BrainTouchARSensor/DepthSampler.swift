import ARKit
import CoreVideo
import Foundation

enum DepthSampler {
    static func sampleDepthMeters(
        at normalizedPoint: HandJoint2D?,
        from depthData: ARDepthData?,
        kernelSize: Int = 5
    ) -> Double? {
        guard let normalizedPoint, let depthData else { return nil }

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        // Vision gives normalized image coordinates. ARKit depth maps often have a lower
        // resolution than the camera image, so normalized coordinates let us map across
        // resolutions without assuming matching pixel dimensions.
        //
        // The current normalizedPoint is already converted for a top-left debug coordinate
        // system in ARSessionModel.convertVisionPointToNormalizedDisplay(_:). We sample the
        // depth map with the same top-left assumption. TODO: Verify rotation/mirroring on
        // the physically mounted iPhone 12 Pro and adjust here if the depth overlay is offset.
        let centerX = clamp(Int(round(normalizedPoint.x * Double(width - 1))), min: 0, max: width - 1)
        let centerY = clamp(Int(round(normalizedPoint.y * Double(height - 1))), min: 0, max: height - 1)

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

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBaseAddress = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let confidenceMatchesDepth = confidenceMap.map {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height
        } ?? false

        let radius = max(0, kernelSize / 2)
        var samples: [Float] = []

        for yOffset in -radius...radius {
            for xOffset in -radius...radius {
                let x = centerX + xOffset
                let y = centerY + yOffset
                guard x >= 0, x < width, y >= 0, y < height else { continue }

                if confidenceMatchesDepth,
                   let confidenceBaseAddress,
                   !isDepthConfidenceUsable(
                    confidenceBaseAddress: confidenceBaseAddress,
                    bytesPerRow: confidenceBytesPerRow,
                    x: x,
                    y: y
                   ) {
                    continue
                }

                let row = depthBaseAddress.advanced(by: y * depthBytesPerRow)
                let value = row.assumingMemoryBound(to: Float32.self)[x]
                if value.isFinite && value > 0 {
                    samples.append(value)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    private static func isDepthConfidenceUsable(
        confidenceBaseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> Bool {
        // ARKit confidence maps are UInt8-like values where 0 is the lowest confidence.
        // We currently reject only the lowest confidence and keep medium/high samples.
        let row = confidenceBaseAddress.advanced(by: y * bytesPerRow)
        let confidence = row.assumingMemoryBound(to: UInt8.self)[x]
        return confidence > 0
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

