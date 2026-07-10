import Foundation
import simd

struct STLBoundingBox: Equatable, Sendable {
    let minX: Float
    let minY: Float
    let minZ: Float
    let maxX: Float
    let maxY: Float
    let maxZ: Float

    var widthUnits: Double { Double(maxX - minX) }
    var depthUnits: Double { Double(maxY - minY) }
    var heightUnits: Double { Double(maxZ - minZ) }

    var widthMetersAssumingMillimeters: Double { widthUnits / 1000 }
    var depthMetersAssumingMillimeters: Double { depthUnits / 1000 }
    var heightMetersAssumingMillimeters: Double { heightUnits / 1000 }

    var centerRaw: SIMD3<Float> {
        SIMD3<Float>(
            (minX + maxX) * 0.5,
            (minY + maxY) * 0.5,
            (minZ + maxZ) * 0.5
        )
    }
}

struct BrainSTLMetadata: Equatable, Sendable {
    let resourceName: String
    let triangleCount: Int
    let boundingBox: STLBoundingBox
    let touchVerticesRaw: [SIMD3<Float>]
    let surfaceTrianglesRaw: [STLTriangle]
    let triangleGrid: STLTriangleGrid

    func scaleForRealWidthMeters(_ realWidthMeters: Double) -> Double {
        guard boundingBox.widthMetersAssumingMillimeters > 0 else { return 1 }
        return realWidthMeters / boundingBox.widthMetersAssumingMillimeters
    }

    func scaledSizeMeters(realWidthMeters: Double) -> (width: Double, depth: Double, height: Double) {
        let scale = scaleForRealWidthMeters(realWidthMeters)
        return (
            width: boundingBox.widthMetersAssumingMillimeters * scale,
            depth: boundingBox.depthMetersAssumingMillimeters * scale,
            height: boundingBox.heightMetersAssumingMillimeters * scale
        )
    }

    func rawUnitToWorldMetersScale(realWidthMeters: Double) -> Double {
        0.001 * scaleForRealWidthMeters(realWidthMeters)
    }
}

struct STLTriangle: Equatable, Sendable {
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let c: SIMD3<Float>
    let normal: SIMD3<Float>

    var centroid: SIMD3<Float> {
        (a + b + c) / 3
    }
}

struct STLTriangleGrid: Equatable, Sendable {
    let resolution: Int
    let cells: [Int: [Int]]
    let boundingBox: STLBoundingBox

    func candidateIndices(near point: SIMD3<Float>, maxRing: Int = 4) -> [Int] {
        let base = cellCoordinates(point)
        var indices: [Int] = []
        for ring in 0...maxRing {
            for z in max(0, base.z - ring)...min(resolution - 1, base.z + ring) {
                for y in max(0, base.y - ring)...min(resolution - 1, base.y + ring) {
                    for x in max(0, base.x - ring)...min(resolution - 1, base.x + ring)
                    where ring == 0 || abs(x - base.x) == ring || abs(y - base.y) == ring || abs(z - base.z) == ring {
                        indices.append(contentsOf: cells[key(x: x, y: y, z: z)] ?? [])
                    }
                }
            }
        }
        return indices
    }

    private func cellCoordinates(_ point: SIMD3<Float>) -> (x: Int, y: Int, z: Int) {
        (
            quantize(point.x, min: boundingBox.minX, max: boundingBox.maxX),
            quantize(point.y, min: boundingBox.minY, max: boundingBox.maxY),
            quantize(point.z, min: boundingBox.minZ, max: boundingBox.maxZ)
        )
    }

    private func quantize(_ value: Float, min: Float, max: Float) -> Int {
        let normalized = (value - min) / Swift.max(max - min, 0.000001)
        return Swift.max(0, Swift.min(resolution - 1, Int(normalized * Float(resolution))))
    }

    private func key(x: Int, y: Int, z: Int) -> Int {
        x + y * resolution + z * resolution * resolution
    }
}

enum BrainSTLMeshLoadError: Error, CustomStringConvertible {
    case resourceNotFound(String)
    case unreadableResource(URL)
    case unsupportedFormat
    case invalidTriangleData

    var description: String {
        switch self {
        case .resourceNotFound(let name):
            return "STL resource not found: \(name)"
        case .unreadableResource(let url):
            return "STL resource could not be read: \(url.lastPathComponent)"
        case .unsupportedFormat:
            return "Only binary STL is supported for now"
        case .invalidTriangleData:
            return "STL triangle data is invalid"
        }
    }
}

enum BrainSTLMeshLoader {
    static let bundledResourceName = "brain_model"
    static let bundledResourceExtension = "stl"
    static let maxTouchSampleVertexCount = 12000
    static let maxSurfaceTriangleCount = 100000

    static func loadBundledMetadata() throws -> BrainSTLMetadata {
        try loadMetadata(
            resourceName: bundledResourceName,
            resourceExtension: bundledResourceExtension
        )
    }

    static func loadMetadata(
        resourceName: String,
        resourceExtension: String
    ) throws -> BrainSTLMetadata {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            throw BrainSTLMeshLoadError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw BrainSTLMeshLoadError.unreadableResource(url)
        }

        return try parseBinarySTLMetadata(
            data: data,
            resourceName: url.lastPathComponent
        )
    }

    static func parseBinarySTLMetadata(
        data: Data,
        resourceName: String
    ) throws -> BrainSTLMetadata {
        guard data.count >= 84 else {
            throw BrainSTLMeshLoadError.unsupportedFormat
        }

        let triangleCount = data.withUnsafeBytes { rawBuffer in
            Int(readUInt32LittleEndian(rawBuffer: rawBuffer, offset: 80))
        }
        let expectedByteCount = 84 + triangleCount * 50
        guard triangleCount > 0, data.count >= expectedByteCount else {
            throw BrainSTLMeshLoadError.invalidTriangleData
        }

        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        var touchVertices: [SIMD3<Float>] = []
        var surfaceTriangles: [STLTriangle] = []
        touchVertices.reserveCapacity(maxTouchSampleVertexCount)
        surfaceTriangles.reserveCapacity(min(triangleCount, maxSurfaceTriangleCount))
        let totalVertexCount = triangleCount * 3
        let touchSampleStep = max(1, totalVertexCount / maxTouchSampleVertexCount)
        let triangleSampleStep = max(1, triangleCount / maxSurfaceTriangleCount)

        try data.withUnsafeBytes { rawBuffer in
            for triangleIndex in 0..<triangleCount {
                let triangleOffset = 84 + triangleIndex * 50
                var triangleVertices: [SIMD3<Float>] = []
                triangleVertices.reserveCapacity(3)
                // Binary STL layout: normal(3 floats), then 3 vertices, then attribute bytes.
                for vertexIndex in 0..<3 {
                    let vertexOffset = triangleOffset + 12 + vertexIndex * 12
                    let x = readFloat32LittleEndian(rawBuffer: rawBuffer, offset: vertexOffset)
                    let y = readFloat32LittleEndian(rawBuffer: rawBuffer, offset: vertexOffset + 4)
                    let z = readFloat32LittleEndian(rawBuffer: rawBuffer, offset: vertexOffset + 8)

                    guard x.isFinite, y.isFinite, z.isFinite else {
                        throw BrainSTLMeshLoadError.invalidTriangleData
                    }

                    minX = min(minX, x)
                    minY = min(minY, y)
                    minZ = min(minZ, z)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                    maxZ = max(maxZ, z)
                    triangleVertices.append(SIMD3<Float>(x, y, z))

                    let globalVertexIndex = triangleIndex * 3 + vertexIndex
                    if globalVertexIndex % touchSampleStep == 0,
                       touchVertices.count < maxTouchSampleVertexCount {
                        touchVertices.append(SIMD3<Float>(x, y, z))
                    }
                }
                if triangleIndex % triangleSampleStep == 0,
                   surfaceTriangles.count < maxSurfaceTriangleCount,
                   triangleVertices.count == 3 {
                    let fileNormal = SIMD3<Float>(
                        readFloat32LittleEndian(rawBuffer: rawBuffer, offset: triangleOffset),
                        readFloat32LittleEndian(rawBuffer: rawBuffer, offset: triangleOffset + 4),
                        readFloat32LittleEndian(rawBuffer: rawBuffer, offset: triangleOffset + 8)
                    )
                    let crossNormal = simd_cross(
                        triangleVertices[1] - triangleVertices[0],
                        triangleVertices[2] - triangleVertices[0]
                    )
                    let normal = simd_length_squared(fileNormal) > 0.000001
                        ? simd_normalize(fileNormal)
                        : simd_normalize(crossNormal)
                    surfaceTriangles.append(STLTriangle(
                        a: triangleVertices[0],
                        b: triangleVertices[1],
                        c: triangleVertices[2],
                        normal: normal
                    ))
                }
            }
        }

        let boundingBox = STLBoundingBox(
            minX: minX,
            minY: minY,
            minZ: minZ,
            maxX: maxX,
            maxY: maxY,
            maxZ: maxZ
        )
        return BrainSTLMetadata(
            resourceName: resourceName,
            triangleCount: triangleCount,
            boundingBox: boundingBox,
            touchVerticesRaw: touchVertices,
            surfaceTrianglesRaw: surfaceTriangles,
            triangleGrid: makeTriangleGrid(triangles: surfaceTriangles, boundingBox: boundingBox)
        )
    }

    private static func makeTriangleGrid(
        triangles: [STLTriangle],
        boundingBox: STLBoundingBox,
        resolution: Int = 24
    ) -> STLTriangleGrid {
        var cells: [Int: [Int]] = [:]
        func quantize(_ value: Float, min: Float, max: Float) -> Int {
            let normalized = (value - min) / Swift.max(max - min, 0.000001)
            return Swift.max(0, Swift.min(resolution - 1, Int(normalized * Float(resolution))))
        }
        for (index, triangle) in triangles.enumerated() {
            let center = triangle.centroid
            let x = quantize(center.x, min: boundingBox.minX, max: boundingBox.maxX)
            let y = quantize(center.y, min: boundingBox.minY, max: boundingBox.maxY)
            let z = quantize(center.z, min: boundingBox.minZ, max: boundingBox.maxZ)
            cells[x + y * resolution + z * resolution * resolution, default: []].append(index)
        }
        return STLTriangleGrid(resolution: resolution, cells: cells, boundingBox: boundingBox)
    }

    private static func readUInt32LittleEndian(
        rawBuffer: UnsafeRawBufferPointer,
        offset: Int
    ) -> UInt32 {
        UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func readFloat32LittleEndian(
        rawBuffer: UnsafeRawBufferPointer,
        offset: Int
    ) -> Float {
        let bitPattern = readUInt32LittleEndian(rawBuffer: rawBuffer, offset: offset)
        return Float(bitPattern: bitPattern)
    }
}
