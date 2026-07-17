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

        // Image pixels use +Y downward, while ARKit camera space uses +Y upward and
        // looks along -Z. Negating the image-space Y offset is therefore required
        // before camera.transform can place the point in AR world space.
        let x = (pixelX - cx) * depthMeters / fx
        let y = -(pixelY - cy) * depthMeters / fy
        let z = -depthMeters

        return SIMD3<Float>(x, y, z)
    }

    static func reprojectionErrorPixels(
        worldPoint: HandJoint3D?,
        sample: DepthSampleResult?,
        camera: ARCamera
    ) -> Double? {
        guard let worldPoint, let sample else { return nil }
        let world = SIMD4<Float>(
            Float(worldPoint.x),
            Float(worldPoint.y),
            Float(worldPoint.z),
            1
        )
        let cameraPoint = simd_inverse(camera.transform) * world
        let depth = -cameraPoint.z
        guard depth > 0 else { return nil }
        let intrinsics = scaledIntrinsicsForDepth(
            camera: camera,
            depthMapSize: CGSize(width: sample.depthMapSize.w, height: sample.depthMapSize.h)
        )
        let pixelX = intrinsics.columns.0.x * cameraPoint.x / depth + intrinsics.columns.2.x
        let pixelY = intrinsics.columns.2.y - intrinsics.columns.1.y * cameraPoint.y / depth
        let dx = Double(pixelX) - Double(sample.depthPixel.x)
        let dy = Double(pixelY) - Double(sample.depthPixel.y)
        return sqrt(dx * dx + dy * dy)
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

        var totalWeight = 0.0
        let sum = samples.enumerated().reduce(HandJoint3D(x: 0, y: 0, z: 0)) { partial, entry in
            let weight = Double(entry.offset + 1)
            totalWeight += weight
            let sample = entry.element
            return HandJoint3D(
                x: partial.x + sample.x * weight,
                y: partial.y + sample.y * weight,
                z: partial.z + sample.z * weight
            )
        }

        return HandJoint3D(
            x: sum.x / totalWeight,
            y: sum.y / totalWeight,
            z: sum.z / totalWeight
        )
    }

    mutating func reset() {
        samples.removeAll()
    }
}
