import Foundation

struct HandJoint2D: Codable, Equatable {
    let x: Double
    let y: Double
}

struct HandJoint3D: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double
}

struct PixelPoint: Codable, Equatable {
    let x: Int
    let y: Int
}

struct PixelSize: Codable, Equatable {
    let w: Int
    let h: Int
}

struct DepthSamplingDebug: Codable, Equatable {
    let depthSample2D: HandJoint2D?
    let rawImageNorm: HandJoint2D?
    let depthPixel: PixelPoint?
    let depthMapSize: PixelSize?
    let capturedImageSize: PixelSize?
    let visionOrientation: String
    let depthConfidenceRaw: Int?
    let depthSource: String
    let depthStrategy: String
    let depthSampleCount: Int
}

struct FingerTips2D: Codable, Equatable {
    let thumbTip: HandJoint2D?
    let indexTip: HandJoint2D?
    let middleTip: HandJoint2D?
    let ringTip: HandJoint2D?
    let littleTip: HandJoint2D?

    enum CodingKeys: String, CodingKey {
        case thumbTip
        case indexTip
        case middleTip
        case ringTip
        case littleTip
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeOptionalAsNull(thumbTip, forKey: .thumbTip)
        try container.encodeOptionalAsNull(indexTip, forKey: .indexTip)
        try container.encodeOptionalAsNull(middleTip, forKey: .middleTip)
        try container.encodeOptionalAsNull(ringTip, forKey: .ringTip)
        try container.encodeOptionalAsNull(littleTip, forKey: .littleTip)
    }
}

struct HandPoseSnapshot: Equatable {
    let handDetected: Bool
    let wrist: HandJoint2D?
    let fingerTips: FingerTips2D
    let indexTipDepthMeters: Double?
    let indexTip3D: HandJoint3D?
    let indexTip3DSpace: String
    let depthDebug: DepthSamplingDebug?
    let touch: TouchDetectionResult
    let confidence: Double

    static let empty = HandPoseSnapshot(
        handDetected: false,
        wrist: nil,
        fingerTips: FingerTips2D(
            thumbTip: nil,
            indexTip: nil,
            middleTip: nil,
            ringTip: nil,
            littleTip: nil
        ),
        indexTipDepthMeters: nil,
        indexTip3D: nil,
        indexTip3DSpace: "arkit_world",
        depthDebug: nil,
        touch: .empty,
        confidence: 0
    )
}

extension KeyedEncodingContainer {
    mutating func encodeOptionalAsNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
