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
            mapping: "stl_raw_xz_y_to_world_xzy_portrait"
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

        let projected = camera.projectPoint(
            worldPoint,
            orientation: .portrait,
            viewportSize: CGSize(width: 1, height: 1)
        )
        guard projected.x.isFinite,
              projected.y.isFinite,
              projected.x >= -0.5,
              projected.x <= 1.5,
              projected.y >= -0.5,
              projected.y <= 1.5 else {
            return nil
        }

        return HandJoint2D(
            x: min(max(Double(projected.x), 0), 1),
            y: min(max(Double(projected.y), 0), 1)
        )
    }
}

private struct BrainSTLPlacement {
    let metadata: BrainSTLMetadata
    let calibration: BrainCalibration

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

        return SIMD3<Float>(
            Float(calibration.centerX) + rotated.x,
            Float(calibration.centerY) + rotated.y,
            Float(calibration.centerZ) + rotated.z
        )
    }
}
