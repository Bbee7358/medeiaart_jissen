import Foundation

struct BrainEllipsoidModel: Equatable {
    var center: HandJoint3D
    var widthMeters: Double
    var depthMeters: Double
    var heightMeters: Double

    var radiusX: Double { widthMeters / 2 }
    var radiusY: Double { heightMeters / 2 }
    var radiusZ: Double { depthMeters / 2 }

    static let provisional = BrainEllipsoidModel(
        center: HandJoint3D(x: 0, y: 0, z: -0.80),
        widthMeters: 0.35,
        depthMeters: 0.25,
        heightMeters: 0.18
    )
}

struct TouchDetectionResult: Codable, Equatable {
    let isCandidate: Bool
    let isStrongCandidate: Bool
    let isTouching: Bool
    let region: String
    let regionLabel: String
    let surface: String
    let surfaceLabel: String
    let distanceCm: Double?
    let durationSec: Double
    let confidence: Double
    let speedMetersPerSec: Double?
}

final class TouchDetector {
    private var model: BrainEllipsoidModel
    private var calibration: BrainCalibration

    private var activeRegion: String?
    private var activeRegionStartedAt: TimeInterval?
    private var lastPoint: HandJoint3D?
    private var lastTimestamp: TimeInterval?

    init(calibration: BrainCalibration = .defaults) {
        self.calibration = calibration
        self.model = calibration.model
    }

    func updateCalibration(_ calibration: BrainCalibration) {
        self.calibration = calibration
        self.model = calibration.model
        resetRegion()
    }

    func update(
        indexTip3D: HandJoint3D?,
        hasDepth: Bool,
        timestamp: TimeInterval,
        meshHit: NearestSurfaceHit? = nil
    ) -> TouchDetectionResult {
        let motionPoint = indexTip3D ?? meshHit?.point
        guard hasDepth, let point = motionPoint else {
            resetRegion()
            updateMotion(point: nil, timestamp: timestamp)
            return .empty
        }

        let speed = updateMotion(point: point, timestamp: timestamp)
        let surface = meshHit.map(SurfaceEstimate.init(meshHit:)) ?? nearestSurface(to: point)
        let absDistance = surface.distanceMeters
        let isCandidate = absDistance <= calibration.touchThresholdMeters
        let isStrongCandidate = absDistance <= calibration.strongThresholdMeters

        let duration = updateDuration(
            region: surface.region,
            isCandidate: isCandidate,
            timestamp: timestamp
        )
        let confidence = confidenceScore(
            distanceMeters: absDistance,
            isCandidate: isCandidate,
            durationSec: duration,
            speedMetersPerSec: speed
        )
        let isTouching = isCandidate
            && duration >= calibration.dwellTimeSeconds
            && confidence >= calibration.confidenceThreshold

        return TouchDetectionResult(
            isCandidate: isCandidate,
            isStrongCandidate: isStrongCandidate,
            isTouching: isTouching,
            region: surface.region,
            regionLabel: surface.regionLabel,
            surface: surface.surface,
            surfaceLabel: surface.surfaceLabel,
            distanceCm: absDistance * 100,
            durationSec: duration,
            confidence: confidence,
            speedMetersPerSec: speed
        )
    }

    private func nearestSurface(to point: HandJoint3D) -> SurfaceEstimate {
        let local = HandJoint3D(
            x: point.x - model.center.x,
            y: point.y - model.center.y,
            z: point.z - model.center.z
        )

        let normalizedLength = sqrt(
            squared(local.x / model.radiusX) +
            squared(local.y / model.radiusY) +
            squared(local.z / model.radiusZ)
        )
        let safeLength = max(normalizedLength, 0.0001)
        let radialScale = 1.0 / safeLength
        let surfaceLocal = HandJoint3D(
            x: local.x * radialScale,
            y: local.y * radialScale,
            z: local.z * radialScale
        )
        let signedDistance = distance(local, surfaceLocal) * (normalizedLength >= 1 ? 1 : -1)

        let nx = abs(surfaceLocal.x / model.radiusX)
        let ny = abs(surfaceLocal.y / model.radiusY)
        let nz = abs(surfaceLocal.z / model.radiusZ)

        if normalizedLength < 0.35 {
            return SurfaceEstimate(
                distanceMeters: abs(signedDistance),
                region: "center",
                regionLabel: "中央",
                surface: "center",
                surfaceLabel: "中央"
            )
        }

        if ny >= nx && ny >= nz && surfaceLocal.y >= 0 {
            return SurfaceEstimate(
                distanceMeters: abs(signedDistance),
                region: "top",
                regionLabel: "上面",
                surface: "top",
                surfaceLabel: "上面"
            )
        }

        if nx >= nz {
            if surfaceLocal.x < 0 {
                return SurfaceEstimate(
                    distanceMeters: abs(signedDistance),
                    region: "left_side",
                    regionLabel: "左側面",
                    surface: "left",
                    surfaceLabel: "左側面"
                )
            }

            return SurfaceEstimate(
                distanceMeters: abs(signedDistance),
                region: "right_side",
                regionLabel: "右側面",
                surface: "right",
                surfaceLabel: "右側面"
            )
        }

        if surfaceLocal.z < 0 {
            return SurfaceEstimate(
                distanceMeters: abs(signedDistance),
                region: "front",
                regionLabel: "前方",
                surface: "front",
                surfaceLabel: "前方"
            )
        }

        return SurfaceEstimate(
            distanceMeters: abs(signedDistance),
            region: "back",
            regionLabel: "後方",
            surface: "back",
            surfaceLabel: "後方"
        )
    }

    private func updateDuration(region: String, isCandidate: Bool, timestamp: TimeInterval) -> Double {
        guard isCandidate else {
            resetRegion()
            return 0
        }

        if activeRegion != region {
            activeRegion = region
            activeRegionStartedAt = timestamp
            return 0
        }

        guard let startedAt = activeRegionStartedAt else {
            activeRegionStartedAt = timestamp
            return 0
        }

        return max(0, timestamp - startedAt)
    }

    private func confidenceScore(
        distanceMeters: Double,
        isCandidate: Bool,
        durationSec: Double,
        speedMetersPerSec: Double?
    ) -> Double {
        guard isCandidate else { return 0 }

        let distanceScore = 1.0 - min(distanceMeters / calibration.touchThresholdMeters, 1.0)
        let durationScore = calibration.dwellTimeSeconds <= 0
            ? 1.0
            : min(durationSec / calibration.dwellTimeSeconds, 1.0)
        let speed = speedMetersPerSec ?? 0
        let speedPenalty = speed <= 0.20 ? 1.0 : max(0.35, 1.0 - ((speed - 0.20) / 0.80))
        return min(max((distanceScore * 0.65 + durationScore * 0.35) * speedPenalty, 0), 1)
    }

    @discardableResult
    private func updateMotion(point: HandJoint3D?, timestamp: TimeInterval) -> Double? {
        defer {
            lastPoint = point
            lastTimestamp = timestamp
        }

        guard let point,
              let lastPoint,
              let lastTimestamp else {
            return nil
        }

        let deltaTime = timestamp - lastTimestamp
        guard deltaTime > 0 else { return nil }

        return distance(point, lastPoint) / deltaTime
    }

    private func resetRegion() {
        activeRegion = nil
        activeRegionStartedAt = nil
    }

    private func distance(_ a: HandJoint3D, _ b: HandJoint3D) -> Double {
        sqrt(squared(a.x - b.x) + squared(a.y - b.y) + squared(a.z - b.z))
    }

    private func squared(_ value: Double) -> Double {
        value * value
    }
}

private struct SurfaceEstimate {
    let distanceMeters: Double
    let region: String
    let regionLabel: String
    let surface: String
    let surfaceLabel: String

    init(
        distanceMeters: Double,
        region: String,
        regionLabel: String,
        surface: String,
        surfaceLabel: String
    ) {
        self.distanceMeters = distanceMeters
        self.region = region
        self.regionLabel = regionLabel
        self.surface = surface
        self.surfaceLabel = surfaceLabel
    }

    init(meshHit: NearestSurfaceHit) {
        let fallbackRegion = Self.region(forSurface: meshHit.surface)
        self.init(
            distanceMeters: meshHit.distanceMeters,
            region: meshHit.regionId ?? fallbackRegion.id,
            regionLabel: meshHit.regionLabel ?? fallbackRegion.label,
            surface: meshHit.surface,
            surfaceLabel: meshHit.surfaceLabel
        )
    }

    private static func region(forSurface surface: String) -> (id: String, label: String) {
        switch surface {
        case "top":
            return ("top", "上面")
        case "left":
            return ("left_side", "左側面")
        case "right":
            return ("right_side", "右側面")
        case "front":
            return ("front", "前方")
        case "back":
            return ("back", "後方")
        default:
            return ("unknown", "不明")
        }
    }
}

extension TouchDetectionResult {
    static let empty = TouchDetectionResult(
        isCandidate: false,
        isStrongCandidate: false,
        isTouching: false,
        region: "unknown",
        regionLabel: "不明",
        surface: "unknown",
        surfaceLabel: "不明",
        distanceCm: nil,
        durationSec: 0,
        confidence: 0,
        speedMetersPerSec: nil
    )
}
