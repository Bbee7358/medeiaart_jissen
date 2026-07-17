import Foundation

struct BrainCalibration: Codable, Equatable {
    var centerX: Double
    var centerY: Double
    var centerZ: Double
    var widthMeters: Double
    var depthMeters: Double
    var heightMeters: Double
    var meshRealWidthMeters: Double
    var meshYawDegrees: Double
    var touchThresholdCm: Double
    var strongTouchThresholdCm: Double
    var dwellTimeSeconds: Double
    var confidenceThreshold: Double
    var smoothingFrames: Int

    static let defaults = BrainCalibration(
        centerX: 0,
        centerY: 0,
        centerZ: -0.80,
        widthMeters: 0.35,
        depthMeters: 0.25,
        heightMeters: 0.18,
        meshRealWidthMeters: 0.15,
        meshYawDegrees: 0,
        touchThresholdCm: 5.0,
        strongTouchThresholdCm: 3.0,
        dwellTimeSeconds: 0.50,
        confidenceThreshold: 0.55,
        smoothingFrames: 5
    )

    init(
        centerX: Double,
        centerY: Double,
        centerZ: Double,
        widthMeters: Double,
        depthMeters: Double,
        heightMeters: Double,
        meshRealWidthMeters: Double,
        meshYawDegrees: Double,
        touchThresholdCm: Double,
        strongTouchThresholdCm: Double,
        dwellTimeSeconds: Double,
        confidenceThreshold: Double,
        smoothingFrames: Int
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.centerZ = centerZ
        self.widthMeters = widthMeters
        self.depthMeters = depthMeters
        self.heightMeters = heightMeters
        self.meshRealWidthMeters = meshRealWidthMeters
        self.meshYawDegrees = meshYawDegrees
        self.touchThresholdCm = touchThresholdCm
        self.strongTouchThresholdCm = strongTouchThresholdCm
        self.dwellTimeSeconds = dwellTimeSeconds
        self.confidenceThreshold = confidenceThreshold
        self.smoothingFrames = smoothingFrames
    }

    enum CodingKeys: String, CodingKey {
        case centerX
        case centerY
        case centerZ
        case widthMeters
        case depthMeters
        case heightMeters
        case meshRealWidthMeters
        case meshYawDegrees
        case touchThresholdCm
        case strongTouchThresholdCm
        case dwellTimeSeconds
        case dwellTimeSec
        case confidenceThreshold
        case smoothingFrames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        centerX = try container.decodeIfPresent(Double.self, forKey: .centerX) ?? defaults.centerX
        centerY = try container.decodeIfPresent(Double.self, forKey: .centerY) ?? defaults.centerY
        centerZ = try container.decodeIfPresent(Double.self, forKey: .centerZ) ?? defaults.centerZ
        widthMeters = try container.decodeIfPresent(Double.self, forKey: .widthMeters) ?? defaults.widthMeters
        depthMeters = try container.decodeIfPresent(Double.self, forKey: .depthMeters) ?? defaults.depthMeters
        heightMeters = try container.decodeIfPresent(Double.self, forKey: .heightMeters) ?? defaults.heightMeters
        meshRealWidthMeters = try container.decodeIfPresent(Double.self, forKey: .meshRealWidthMeters) ?? defaults.meshRealWidthMeters
        meshYawDegrees = try container.decodeIfPresent(Double.self, forKey: .meshYawDegrees) ?? defaults.meshYawDegrees
        touchThresholdCm = try container.decodeIfPresent(Double.self, forKey: .touchThresholdCm) ?? defaults.touchThresholdCm
        strongTouchThresholdCm = try container.decodeIfPresent(Double.self, forKey: .strongTouchThresholdCm) ?? defaults.strongTouchThresholdCm
        dwellTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .dwellTimeSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .dwellTimeSec)
            ?? defaults.dwellTimeSeconds
        confidenceThreshold = try container.decodeIfPresent(Double.self, forKey: .confidenceThreshold) ?? defaults.confidenceThreshold
        smoothingFrames = try container.decodeIfPresent(Int.self, forKey: .smoothingFrames) ?? defaults.smoothingFrames
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(centerX, forKey: .centerX)
        try container.encode(centerY, forKey: .centerY)
        try container.encode(centerZ, forKey: .centerZ)
        try container.encode(widthMeters, forKey: .widthMeters)
        try container.encode(depthMeters, forKey: .depthMeters)
        try container.encode(heightMeters, forKey: .heightMeters)
        try container.encode(meshRealWidthMeters, forKey: .meshRealWidthMeters)
        try container.encode(meshYawDegrees, forKey: .meshYawDegrees)
        try container.encode(touchThresholdCm, forKey: .touchThresholdCm)
        try container.encode(strongTouchThresholdCm, forKey: .strongTouchThresholdCm)
        try container.encode(dwellTimeSeconds, forKey: .dwellTimeSeconds)
        try container.encode(confidenceThreshold, forKey: .confidenceThreshold)
        try container.encode(smoothingFrames, forKey: .smoothingFrames)
    }

    var model: BrainEllipsoidModel {
        BrainEllipsoidModel(
            center: HandJoint3D(x: centerX, y: centerY, z: centerZ),
            widthMeters: widthMeters,
            depthMeters: depthMeters,
            heightMeters: heightMeters
        )
    }

    var touchThresholdMeters: Double {
        touchThresholdCm / 100
    }

    var strongThresholdMeters: Double {
        strongTouchThresholdCm / 100
    }
}

enum BrainCalibrationStore {
    private static let key = "brainTouch.calibration.v1"

    static func load() -> BrainCalibration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let calibration = try? JSONDecoder().decode(BrainCalibration.self, from: data) else {
            return .defaults
        }

        return sanitized(calibration)
    }

    static func save(_ calibration: BrainCalibration) {
        guard let data = try? JSONEncoder().encode(sanitized(calibration)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() -> BrainCalibration {
        UserDefaults.standard.removeObject(forKey: key)
        return .defaults
    }

    static func sanitized(_ calibration: BrainCalibration) -> BrainCalibration {
        BrainCalibration(
            centerX: calibration.centerX,
            centerY: calibration.centerY,
            centerZ: calibration.centerZ,
            widthMeters: clamp(calibration.widthMeters, min: 0.05, max: 1.00),
            depthMeters: clamp(calibration.depthMeters, min: 0.05, max: 1.00),
            heightMeters: clamp(calibration.heightMeters, min: 0.05, max: 1.00),
            meshRealWidthMeters: clamp(calibration.meshRealWidthMeters, min: 0.03, max: 1.00),
            meshYawDegrees: clamp(calibration.meshYawDegrees, min: -180.0, max: 180.0),
            touchThresholdCm: clamp(calibration.touchThresholdCm, min: 0.5, max: 8.0),
            strongTouchThresholdCm: clamp(calibration.strongTouchThresholdCm, min: 0.5, max: 8.0),
            dwellTimeSeconds: clamp(calibration.dwellTimeSeconds, min: 0.0, max: 3.0),
            confidenceThreshold: clamp(calibration.confidenceThreshold, min: 0.0, max: 1.0),
            smoothingFrames: Int(clamp(Double(calibration.smoothingFrames), min: 1, max: 30))
        )
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}
