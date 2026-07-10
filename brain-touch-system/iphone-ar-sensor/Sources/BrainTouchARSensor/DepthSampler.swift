import ARKit
import CoreGraphics
import CoreVideo
import Foundation

struct DepthSampleResult {
    let depthMeters: Double
    let sampleDisplayPoint: HandJoint2D
    let rawImageNormalized: HandJoint2D
    let depthPixel: PixelPoint
    let depthMapSize: PixelSize
    let capturedImageSize: PixelSize
    let visionOrientation: String
    let depthConfidenceRaw: Int?
    let depthSource: String
    let depthStrategy: String
    let sampleCount: Int
}

enum DepthSampler {
    static func sampleIndexFingerDepth(
        indexTipVisionPoint: CGPoint?,
        indexDIPVisionPoint: CGPoint?,
        depthData: ARDepthData?,
        capturedImage: CVPixelBuffer,
        depthSource: String,
        kernelSize: Int = 7
    ) -> DepthSampleResult? {
        guard let indexTipVisionPoint, let depthData else { return nil }

        _ = indexDIPVisionPoint
        let sampleVisionPoint = indexTipVisionPoint
        let strategy = "exact_tip_high_confidence_median"

        return sampleDepth(
            visionPoint: sampleVisionPoint,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: kernelSize,
            strategy: strategy
        )
    }

    static func sampleHandJointDepth(
        visionPoint: CGPoint?,
        jointName: String,
        depthData: ARDepthData?,
        capturedImage: CVPixelBuffer,
        depthSource: String,
        kernelSize: Int = 5
    ) -> DepthSampleResult? {
        guard let visionPoint, let depthData else { return nil }

        return sampleDepth(
            visionPoint: visionPoint,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: kernelSize,
            strategy: "\(jointName)_high_confidence_median"
        )
    }

    static func sampleFingerContactDepth(
        tipVisionPoint: CGPoint?,
        dipVisionPoint: CGPoint?,
        fingerName: String,
        depthData: ARDepthData?,
        capturedImage: CVPixelBuffer,
        depthSource: String,
        kernelSize: Int = 7
    ) -> DepthSampleResult? {
        guard let tipVisionPoint, let depthData else { return nil }

        _ = dipVisionPoint
        let sampleVisionPoint = tipVisionPoint
        let strategy = "\(fingerName)_exact_tip_high_confidence_median"

        return sampleDepth(
            visionPoint: sampleVisionPoint,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: kernelSize,
            strategy: strategy
        )
    }

    private static func sampleDepth(
        visionPoint: CGPoint,
        depthData: ARDepthData,
        capturedImage: CVPixelBuffer,
        depthSource: String,
        kernelSize: Int,
        strategy: String
    ) -> DepthSampleResult? {
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return nil }

        let rawImageNormalized = visionPointToRawImageNormalizedPortraitBack(visionPoint)
        guard rawImageNormalized.x >= 0,
              rawImageNormalized.x <= 1,
              rawImageNormalized.y >= 0,
              rawImageNormalized.y <= 1 else {
            return nil
        }

        let centerX = clamp(Int(round(rawImageNormalized.x * CGFloat(depthWidth - 1))), min: 0, max: depthWidth - 1)
        let centerY = clamp(Int(round(rawImageNormalized.y * CGFloat(depthHeight - 1))), min: 0, max: depthHeight - 1)

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

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceMap = depthData.confidenceMap
        let confidenceBaseAddress = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let confidenceMatchesDepth = confidenceMap.map {
            CVPixelBufferGetWidth($0) == depthWidth && CVPixelBufferGetHeight($0) == depthHeight
        } ?? false

        let radius = max(0, kernelSize / 2)
        var highConfidenceSamples: [Float] = []
        var mediumConfidenceSamples: [Float] = []
        let centerConfidence = confidenceBaseAddress.flatMap {
            readConfidenceRaw(
                confidenceBaseAddress: $0,
                bytesPerRow: confidenceBytesPerRow,
                x: centerX,
                y: centerY
            )
        }

        for yOffset in -radius...radius {
            for xOffset in -radius...radius {
                let x = centerX + xOffset
                let y = centerY + yOffset
                guard x >= 0, x < depthWidth, y >= 0, y < depthHeight else { continue }

                let row = depthBaseAddress.advanced(by: y * depthBytesPerRow)
                let value = row.assumingMemoryBound(to: Float32.self)[x]
                if value.isFinite && value >= 0.10 && value <= 2.00 {
                    let confidence = confidenceMatchesDepth && confidenceBaseAddress != nil
                        ? readConfidenceRaw(
                            confidenceBaseAddress: confidenceBaseAddress!,
                            bytesPerRow: confidenceBytesPerRow,
                            x: x,
                            y: y
                        )
                        : 2
                    if confidence == 2 {
                        highConfidenceSamples.append(value)
                    } else if confidence == 1 {
                        mediumConfidenceSamples.append(value)
                    }
                }
            }
        }

        var samples = highConfidenceSamples.count >= 3
            ? highConfidenceSamples
            : highConfidenceSamples + mediumConfidenceSamples
        guard samples.count >= 3 else { return nil }
        samples.sort()
        let selectedDepth = samples[samples.count / 2]

        return DepthSampleResult(
            depthMeters: Double(selectedDepth),
            sampleDisplayPoint: convertVisionPointToNormalizedDisplay(visionPoint),
            rawImageNormalized: HandJoint2D(
                x: Double(rawImageNormalized.x),
                y: Double(rawImageNormalized.y)
            ),
            depthPixel: PixelPoint(x: centerX, y: centerY),
            depthMapSize: PixelSize(w: depthWidth, h: depthHeight),
            capturedImageSize: PixelSize(
                w: CVPixelBufferGetWidth(capturedImage),
                h: CVPixelBufferGetHeight(capturedImage)
            ),
            visionOrientation: "right",
            depthConfidenceRaw: centerConfidence.map(Int.init),
            depthSource: depthSource,
            depthStrategy: strategy,
            sampleCount: samples.count
        )
    }

    static func convertVisionPointToNormalizedDisplay(_ point: CGPoint) -> HandJoint2D {
        HandJoint2D(
            x: Double(point.x),
            y: Double(1.0 - point.y)
        )
    }

    // For the current installation we intentionally lock the math to back camera + portrait
    // + VNImageRequestHandler orientation .right. If the yellow dot and depth sample move in
    // opposite directions on-device, this inverse rotation is the first place to adjust.
    private static func visionPointToRawImageNormalizedPortraitBack(_ point: CGPoint) -> CGPoint {
        let orientedTopLeft = CGPoint(x: point.x, y: 1.0 - point.y)
        return CGPoint(
            x: orientedTopLeft.y,
            y: 1.0 - orientedTopLeft.x
        )
    }

    private static func readConfidenceRaw(
        confidenceBaseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> UInt8? {
        let row = confidenceBaseAddress.advanced(by: y * bytesPerRow)
        return row.assumingMemoryBound(to: UInt8.self)[x]
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}
