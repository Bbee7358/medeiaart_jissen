import Foundation
import simd

struct STLBoundingBox: Equatable {
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

struct BrainSTLMetadata: Equatable {
    let resourceName: String
    let triangleCount: Int
    let boundingBox: STLBoundingBox
    let touchVerticesRaw: [SIMD3<Float>]

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
        touchVertices.reserveCapacity(maxTouchSampleVertexCount)
        let totalVertexCount = triangleCount * 3
        let touchSampleStep = max(1, totalVertexCount / maxTouchSampleVertexCount)

        try data.withUnsafeBytes { rawBuffer in
            for triangleIndex in 0..<triangleCount {
                let triangleOffset = 84 + triangleIndex * 50
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

                    let globalVertexIndex = triangleIndex * 3 + vertexIndex
                    if globalVertexIndex % touchSampleStep == 0,
                       touchVertices.count < maxTouchSampleVertexCount {
                        touchVertices.append(SIMD3<Float>(x, y, z))
                    }
                }
            }
        }

        return BrainSTLMetadata(
            resourceName: resourceName,
            triangleCount: triangleCount,
            boundingBox: STLBoundingBox(
                minX: minX,
                minY: minY,
                minZ: minZ,
                maxX: maxX,
                maxY: maxY,
                maxZ: maxZ
            ),
            touchVerticesRaw: touchVertices
        )
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
