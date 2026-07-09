import ARKit
import Foundation
import simd

enum PointUnprojector {
    static let outputCoordinateSpace = "arkit_world"

    static func unprojectPoint(
        normalizedPoint: HandJoint2D?,
        depthMeters: Double?,
        camera: ARCamera
    ) -> HandJoint3D? {
        guard let normalizedPoint,
              let depthMeters,
              depthMeters.isFinite,
              depthMeters > 0 else {
            return nil
        }

        let imageResolution = camera.imageResolution
        guard imageResolution.width > 0, imageResolution.height > 0 else {
            return nil
        }

        let pixelX = Float(normalizedPoint.x * Double(imageResolution.width))
        let pixelY = Float(normalizedPoint.y * Double(imageResolution.height))
        let depth = Float(depthMeters)
        let cameraSpacePoint = unprojectPoint(
            pixelX: pixelX,
            pixelY: pixelY,
            depthMeters: depth,
            intrinsics: camera.intrinsics
        )

        let worldPoint = camera.transform * SIMD4<Float>(
            cameraSpacePoint.x,
            cameraSpacePoint.y,
            cameraSpacePoint.z,
            1
        )

        return HandJoint3D(
            x: Double(worldPoint.x),
            y: Double(worldPoint.y),
            z: Double(worldPoint.z)
        )
    }

    static func unprojectDepthSample(
        _ sample: DepthSampleResult?,
        camera: ARCamera
    ) -> HandJoint3D? {
        guard let sample,
              sample.depthMeters.isFinite,
              sample.depthMeters > 0 else {
            return nil
        }

        let depthMapSize = CGSize(width: sample.depthMapSize.w, height: sample.depthMapSize.h)
        guard depthMapSize.width > 0, depthMapSize.height > 0 else {
            return nil
        }

        let scaledIntrinsics = scaledIntrinsicsForDepth(
            camera: camera,
            depthMapSize: depthMapSize
        )
        let cameraSpacePoint = unprojectPoint(
            pixelX: Float(sample.depthPixel.x),
            pixelY: Float(sample.depthPixel.y),
            depthMeters: Float(sample.depthMeters),
            intrinsics: scaledIntrinsics
        )

        let worldPoint = camera.transform * SIMD4<Float>(
            cameraSpacePoint.x,
            cameraSpacePoint.y,
            cameraSpacePoint.z,
            1
        )

        return HandJoint3D(
            x: Double(worldPoint.x),
            y: Double(worldPoint.y),
            z: Double(worldPoint.z)
        )
    }

    static func scaledIntrinsicsForDepth(
        camera: ARCamera,
        depthMapSize: CGSize
    ) -> simd_float3x3 {
        var intrinsics = camera.intrinsics
        let imageResolution = camera.imageResolution

        guard imageResolution.width > 0,
              imageResolution.height > 0,
              depthMapSize.width > 0,
              depthMapSize.height > 0 else {
            return intrinsics
        }

        let scaleX = Float(depthMapSize.width / imageResolution.width)
        let scaleY = Float(depthMapSize.height / imageResolution.height)

        intrinsics.columns.0.x *= scaleX
        intrinsics.columns.1.y *= scaleY
        intrinsics.columns.2.x *= scaleX
        intrinsics.columns.2.y *= scaleY

        return intrinsics
    }

    static func unprojectPoint(
        pixelX: Float,
        pixelY: Float,
        depthMeters: Float,
        intrinsics: simd_float3x3
    ) -> SIMD3<Float> {
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        guard fx != 0, fy != 0 else {
            return SIMD3<Float>(0, 0, -depthMeters)
        }

        // Camera space used here: +X image right, +Y image down, camera looks along -Z.
        // ARKit's camera intrinsics are expressed in image pixel coordinates with a
        // top-left origin, so keeping image Y positive downward prevents vertical
        // mirroring when depth-map pixels are unprojected back into the AR camera ray.
        // TODO: Recheck this if the final installation uses a landscape mount.
        let x = (pixelX - cx) * depthMeters / fx
        let y = (pixelY - cy) * depthMeters / fy
        let z = -depthMeters

        return SIMD3<Float>(x, y, z)
    }
}

struct Point3DSmoother {
    private let maxSampleCount: Int
    private var samples: [HandJoint3D] = []

    init(maxSampleCount: Int = 5) {
        self.maxSampleCount = max(1, maxSampleCount)
    }

    mutating func append(_ point: HandJoint3D?) -> HandJoint3D? {
        guard let point else {
            samples.removeAll()
            return nil
        }

        samples.append(point)
        if samples.count > maxSampleCount {
            samples.removeFirst(samples.count - maxSampleCount)
        }

        let count = Double(samples.count)
        let sum = samples.reduce(HandJoint3D(x: 0, y: 0, z: 0)) { partial, sample in
            HandJoint3D(
                x: partial.x + sample.x,
                y: partial.y + sample.y,
                z: partial.z + sample.z
            )
        }

        return HandJoint3D(
            x: sum.x / count,
            y: sum.y / count,
            z: sum.z / count
        )
    }

    mutating func reset() {
        samples.removeAll()
    }
}
