import Foundation
import simd

struct SampledBrainSTLSurfaceModel: BrainSurfaceModel {
    let metadata: BrainSTLMetadata
    let calibration: BrainCalibration

    var modelId: String { metadata.resourceName }
    var coordinateSpace: String { PointUnprojector.outputCoordinateSpace }

    func nearestSurfaceHit(to point: HandJoint3D) -> NearestSurfaceHit? {
        guard !metadata.surfaceTrianglesRaw.isEmpty else { return nil }

        let placement = BrainSTLPlacement(metadata: metadata, calibration: calibration)
        let target = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
        let rawTarget = placement.rawPoint(forWorldPoint: target)
        var bestPoint: SIMD3<Float>?
        var bestRawPoint: SIMD3<Float>?
        var bestNormal: SIMD3<Float>?
        var bestTriangleId: Int?
        var bestDistanceSquared = Float.greatestFiniteMagnitude

        let candidateIndices = metadata.triangleGrid.candidateIndices(near: rawTarget)
        for triangleIndex in candidateIndices {
            let triangle = metadata.surfaceTrianglesRaw[triangleIndex]
            let rawPoint = closestPoint(
                to: rawTarget,
                a: triangle.a,
                b: triangle.b,
                c: triangle.c
            )
            let worldPoint = placement.worldPoint(forRawVertex: rawPoint)
            let delta = worldPoint - target
            let distanceSquared = simd_length_squared(delta)
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestPoint = worldPoint
                bestRawPoint = rawPoint
                bestNormal = placement.worldNormal(forRawNormal: triangle.normal)
                bestTriangleId = triangleIndex
            }
        }

        guard let bestPoint, let bestRawPoint, let bestNormal else { return nil }
        let rawOutward = bestRawPoint - metadata.boundingBox.centerRaw
        let normalVector = simd_dot(bestNormal, placement.worldDirection(forRawDirection: rawOutward)) >= 0
            ? bestNormal
            : -bestNormal
        let surface = surfaceClassification(normal: normalVector)
        let contactProfile = makeContactProfile(
            rawVertex: bestRawPoint,
            boundingBox: metadata.boundingBox,
            normal: normalVector
        )
        let block = BrainRegionBlockClassifier.classify(
            rawVertex: bestRawPoint,
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
            triangleId: bestTriangleId,
            regionId: block.id,
            regionLabel: block.label,
            surface: surface.id,
            surfaceLabel: surface.label,
            confidence: confidence,
            contactProfile: contactProfile
        )
    }

    private func closestPoint(
        to point: SIMD3<Float>,
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>
    ) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            return a + (d1 / (d1 - d3)) * ab
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            return a + (d2 / (d2 - d6)) * ac
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let edge = c - b
            return b + ((d4 - d3) / ((d4 - d3) + (d5 - d6))) * edge
        }

        let denominator = 1 / (va + vb + vc)
        let v = vb * denominator
        let w = vc * denominator
        return a + ab * v + ac * w
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

    private func makeContactProfile(
        rawVertex: SIMD3<Float>,
        boundingBox: STLBoundingBox,
        normal: SIMD3<Float>
    ) -> SurfaceContactProfile {
        let x = normalized(rawVertex.x, min: boundingBox.minX, max: boundingBox.maxX)
        let y = normalized(rawVertex.y, min: boundingBox.minY, max: boundingBox.maxY)
        let z = normalized(rawVertex.z, min: boundingBox.minZ, max: boundingBox.maxZ)
        let nx = Double(normal.x)
        let ny = Double(normal.y)
        let nz = Double(normal.z)
        let horizontal = min(max(sqrt(nx * nx + nz * nz), 0), 1)

        return SurfaceContactProfile(
            modelPosition01: HandJoint3D(x: x, y: y, z: z),
            surfaceNormal: HandJoint3D(x: nx, y: ny, z: nz),
            topness: clamp(Double(normal.y), min: 0, max: 1),
            sideness: horizontal,
            leftness: clamp(-nx, min: 0, max: 1),
            rightness: clamp(nx, min: 0, max: 1),
            frontness: clamp(-nz, min: 0, max: 1),
            backness: clamp(nz, min: 0, max: 1)
        )
    }

    private func normalized(_ value: Float, min minValue: Float, max maxValue: Float) -> Double {
        let span = max(maxValue - minValue, 0.000001)
        return Double(Swift.max(0, Swift.min(1, (value - minValue) / span)))
    }

    private func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
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

    func rawPoint(forWorldPoint world: SIMD3<Float>) -> SIMD3<Float> {
        let offset = world - worldCenter
        let yaw = Float(calibration.meshYawDegrees * .pi / 180)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let local = SIMD3<Float>(
            offset.x * cosYaw + offset.z * sinYaw,
            offset.y,
            -offset.x * sinYaw + offset.z * cosYaw
        )
        let scale = Float(metadata.rawUnitToWorldMetersScale(
            realWidthMeters: calibration.meshRealWidthMeters
        ))
        let center = metadata.boundingBox.centerRaw
        guard scale > 0 else { return center }
        return SIMD3<Float>(
            local.x / scale + center.x,
            local.z / scale + center.y,
            local.y / scale + center.z
        )
    }

    func worldNormal(forRawNormal raw: SIMD3<Float>) -> SIMD3<Float> {
        let local = SIMD3<Float>(raw.x, raw.z, raw.y)
        let yaw = Float(calibration.meshYawDegrees * .pi / 180)
        let rotated = SIMD3<Float>(
            local.x * cos(yaw) - local.z * sin(yaw),
            local.y,
            local.x * sin(yaw) + local.z * cos(yaw)
        )
        return simd_length_squared(rotated) > 0.000001
            ? simd_normalize(rotated)
            : SIMD3<Float>(0, 1, 0)
    }

    func worldDirection(forRawDirection raw: SIMD3<Float>) -> SIMD3<Float> {
        let local = SIMD3<Float>(raw.x, raw.z, raw.y)
        let yaw = Float(calibration.meshYawDegrees * .pi / 180)
        return SIMD3<Float>(
            local.x * cos(yaw) - local.z * sin(yaw),
            local.y,
            local.x * sin(yaw) + local.z * cos(yaw)
        )
    }
}
