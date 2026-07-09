import ARKit
import Foundation
import UIKit
import simd

struct STLProjectionOverlaySnapshot: Equatable {
    let points: [HandJoint2D]
    let centroid: HandJoint2D
    let boundsMin: HandJoint2D
    let boundsMax: HandJoint2D
    let projectedPointCount: Int
    let sourceSampleCount: Int
    let mapping: String

    static let empty = STLProjectionOverlaySnapshot(
        points: [],
        centroid: HandJoint2D(x: 0.5, y: 0.5),
        boundsMin: HandJoint2D(x: 0.5, y: 0.5),
        boundsMax: HandJoint2D(x: 0.5, y: 0.5),
        projectedPointCount: 0,
        sourceSampleCount: 0,
        mapping: "none"
    )
}

enum BrainSTLProjector {
    static func makeOverlay(
        metadata: BrainSTLMetadata?,
        calibration: BrainCalibration,
        camera: ARCamera
    ) -> STLProjectionOverlaySnapshot {
        guard let metadata,
              !metadata.sampleVerticesRaw.isEmpty else {
            return .empty
        }

        let placement = BrainSTLPlacement(metadata: metadata, calibration: calibration)
        var points: [HandJoint2D] = []
        points.reserveCapacity(metadata.sampleVerticesRaw.count)

        for rawVertex in metadata.sampleVerticesRaw {
            let worldPoint = placement.worldPoint(forRawVertex: rawVertex)
            guard let projected = projectWorldPointToDisplay(
                worldPoint,
                camera: camera
            ) else {
                continue
            }

            points.append(projected)
        }

        guard !points.isEmpty else {
            return STLProjectionOverlaySnapshot(
                points: [],
                centroid: HandJoint2D(x: 0.5, y: 0.5),
                boundsMin: HandJoint2D(x: 0.5, y: 0.5),
                boundsMax: HandJoint2D(x: 0.5, y: 0.5),
                projectedPointCount: 0,
                sourceSampleCount: metadata.sampleVerticesRaw.count,
                mapping: "stl_world_projection_empty"
            )
        }

        let minX = points.map(\.x).min() ?? 0.5
        let minY = points.map(\.y).min() ?? 0.5
        let maxX = points.map(\.x).max() ?? 0.5
        let maxY = points.map(\.y).max() ?? 0.5
        let centroid = points.reduce(HandJoint2D(x: 0, y: 0)) { partial, point in
            HandJoint2D(x: partial.x + point.x, y: partial.y + point.y)
        }
        let count = Double(points.count)

        return STLProjectionOverlaySnapshot(
            points: points,
            centroid: HandJoint2D(x: centroid.x / count, y: centroid.y / count),
            boundsMin: HandJoint2D(x: minX, y: minY),
            boundsMax: HandJoint2D(x: maxX, y: maxY),
            projectedPointCount: points.count,
            sourceSampleCount: metadata.sampleVerticesRaw.count,
            mapping: "stl_world_to_raw_camera_to_display"
        )
    }

    private static func projectWorldPointToDisplay(
        _ worldPoint: SIMD3<Float>,
        camera: ARCamera
    ) -> HandJoint2D? {
        let cameraPoint4 = camera.transform.inverse * SIMD4<Float>(
            worldPoint.x,
            worldPoint.y,
            worldPoint.z,
            1
        )

        // ARKit camera space looks along -Z. Points with z >= 0 are behind the camera.
        guard cameraPoint4.z < -0.001 else { return nil }

        let intrinsics = camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let imageResolution = camera.imageResolution
        guard fx > 0,
              fy > 0,
              imageResolution.width > 0,
              imageResolution.height > 0 else {
            return nil
        }

        let positiveDepth = -cameraPoint4.z
        let rawX = (cameraPoint4.x * fx / positiveDepth + cx) / Float(imageResolution.width)
        let rawY = (cameraPoint4.y * fy / positiveDepth + cy) / Float(imageResolution.height)
        guard rawX.isFinite,
              rawY.isFinite,
              rawX >= -0.5,
              rawX <= 1.5,
              rawY >= -0.5,
              rawY <= 1.5 else {
            return nil
        }

        // Match DepthBrainCalibrator.depthPixelToDisplayPoint(_:). The LiDAR
        // debug overlay already proved this portrait/back-camera raw->display
        // mapping against the physical model, so STL projection should use the
        // same route instead of ARCamera.projectPoint(.portrait).
        return HandJoint2D(
            x: min(max(1.0 - Double(rawY), 0), 1),
            y: min(max(Double(rawX), 0), 1)
        )
    }
}

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
        let block = blockClassification(rawVertex: bestRawVertex)
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

    private func blockClassification(rawVertex: SIMD3<Float>) -> (id: String, label: String) {
        let box = metadata.boundingBox
        let xRatio = normalized(rawVertex.x, min: box.minX, max: box.maxX)
        let yRatio = normalized(rawVertex.y, min: box.minY, max: box.maxY)
        let zRatio = normalized(rawVertex.z, min: box.minZ, max: box.maxZ)

        let layerId: String
        let layerLabel: String
        if zRatio >= 0.52 {
            layerId = "top"
            layerLabel = "上段"
        } else {
            layerId = "side_lower"
            layerLabel = "側面下段"
        }

        let depthId: String
        let depthLabel: String
        if yRatio < 0.34 {
            depthId = "front"
            depthLabel = "前"
        } else if yRatio < 0.67 {
            depthId = "middle"
            depthLabel = "中央"
        } else {
            depthId = "back"
            depthLabel = "後"
        }

        let sideId: String
        let sideLabel: String
        if xRatio < 0.50 {
            sideId = "left"
            sideLabel = "左"
        } else {
            sideId = "right"
            sideLabel = "右"
        }

        return (
            "\(layerId)_\(depthId)_\(sideId)",
            "\(layerLabel)・\(depthLabel)\(sideLabel)"
        )
    }

    private func normalized(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        let span = max(maxValue - minValue, 0.000001)
        return Swift.max(0, Swift.min(1, (value - minValue) / span))
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
