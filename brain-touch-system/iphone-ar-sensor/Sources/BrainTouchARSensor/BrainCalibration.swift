import Foundation

struct BrainCalibration: Codable, Equatable {
    var centerX: Double
    var centerY: Double
    var centerZ: Double
    var widthMeters: Double
    var depthMeters: Double
    var heightMeters: Double
    var touchThresholdCm: Double
    var dwellTimeSeconds: Double
    var confidenceThreshold: Double

    static let defaults = BrainCalibration(
        centerX: 0,
        centerY: 0,
        centerZ: -0.80,
        widthMeters: 0.35,
        depthMeters: 0.25,
        heightMeters: 0.18,
        touchThresholdCm: 5.0,
        dwellTimeSeconds: 0.50,
        confidenceThreshold: 0.55
    )

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
        max(0.005, touchThresholdMeters * 0.60)
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
            touchThresholdCm: clamp(calibration.touchThresholdCm, min: 0.5, max: 20.0),
            dwellTimeSeconds: clamp(calibration.dwellTimeSeconds, min: 0.0, max: 3.0),
            confidenceThreshold: clamp(calibration.confidenceThreshold, min: 0.0, max: 1.0)
        )
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}
