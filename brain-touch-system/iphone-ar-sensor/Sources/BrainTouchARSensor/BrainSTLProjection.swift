import Foundation
import simd

struct SampledBrainSTLSurfaceModel: BrainSurfaceModel {
    let metadata: BrainSTLMetadata
    let calibration: BrainCalibration

    var modelId: String { metadata.resourceName }
    var coordinateSpace: String { PointUnprojector.outputCoordinateSpace }

    func nearestSurfaceHit(to point: HandJoint3D) -> NearestSurfaceHit? {
        guard !metadata.touchVerticesRaw.isEmpty else { return nil }

        let placement = BrainSTLPlacement(metadata: metadata, calibration: calibration)
        let target = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
        var bestPoint: SIMD3<Float>?
        var bestRawVertex: SIMD3<Float>?
        var bestDistanceSquared = Float.greatestFiniteMagnitude

        for rawVertex in metadata.touchVerticesRaw {
            let worldPoint = placement.worldPoint(forRawVertex: rawVertex)
            let delta = worldPoint - target
            let distanceSquared = simd_length_squared(delta)
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestPoint = worldPoint
                bestRawVertex = rawVertex
            }
        }

        guard let bestPoint, let bestRawVertex else { return nil }

        let worldCenter = placement.worldCenter
        let centerDelta = bestPoint - worldCenter
        let normalVector = simd_length_squared(centerDelta) > 0.000001
            ? simd_normalize(centerDelta)
            : SIMD3<Float>(0, 1, 0)
        let surface = surfaceClassification(normal: normalVector)
        let block = BrainRegionBlockClassifier.classify(
            rawVertex: bestRawVertex,
            boundingBox: metadata.boundingBox,
            surface: surface,
            normal: normalVector
        )
        let distanceMeters = Double(sqrt(bestDistanceSquared))
        let threshold = max(calibration.touchThresholdMeters, 0.001)
        let confidence = max(0, 1.0 - min(distanceMeters / threshold, 1.0))

        return NearestSurfaceHit(
            point: HandJoint3D(
                x: Double(bestPoint.x),
                y: Double(bestPoint.y),
                z: Double(bestPoint.z)
            ),
            normal: HandJoint3D(
                x: Double(normalVector.x),
                y: Double(normalVector.y),
                z: Double(normalVector.z)
            ),
            distanceMeters: distanceMeters,
            triangleId: nil,
            regionId: block.id,
            regionLabel: block.label,
            surface: surface.id,
            surfaceLabel: surface.label,
            confidence: confidence
        )
    }

    private func surfaceClassification(normal: SIMD3<Float>) -> (id: String, label: String) {
        let ax = abs(normal.x)
        let ay = abs(normal.y)
        let az = abs(normal.z)

        if ay >= ax && ay >= az && normal.y >= 0 {
            return ("top", "上面")
        }

        if ax >= az {
            return normal.x < 0 ? ("left", "左側面") : ("right", "右側面")
        }

        return normal.z < 0 ? ("front", "前方") : ("back", "後方")
    }

}

struct BrainSTLPlacement {
    let metadata: BrainSTLMetadata
    let calibration: BrainCalibration

    var worldCenter: SIMD3<Float> {
        SIMD3<Float>(
            Float(calibration.centerX),
            Float(calibration.centerY),
            Float(calibration.centerZ)
        )
    }

    func worldPoint(forRawVertex raw: SIMD3<Float>) -> SIMD3<Float> {
        let rawCenter = metadata.boundingBox.centerRaw
        let metersPerRawUnit = Float(metadata.rawUnitToWorldMetersScale(
            realWidthMeters: calibration.meshRealWidthMeters
        ))

        // STL raw axes are treated as x=width, y=depth, z=height.
        // ARKit world axes are treated as x=width, y=height, z=depth.
        // TODO: Confirm this axis mapping against the final exported STL orientation.
        let local = SIMD3<Float>(
            (raw.x - rawCenter.x) * metersPerRawUnit,
            (raw.z - rawCenter.z) * metersPerRawUnit,
            (raw.y - rawCenter.y) * metersPerRawUnit
        )
        let yaw = Float(calibration.meshYawDegrees * .pi / 180)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let rotated = SIMD3<Float>(
            local.x * cosYaw - local.z * sinYaw,
            local.y,
            local.x * sinYaw + local.z * cosYaw
        )

        return worldCenter + rotated
    }
}
