import Foundation

enum BrainTouchDetectionMode: String, Codable, Equatable {
    case ellipsoid
    case mesh
    case hybrid
}

struct SurfaceContactProfile: Codable, Equatable {
    let modelPosition01: HandJoint3D
    let surfaceNormal: HandJoint3D
    let topness: Double
    let sideness: Double
    let leftness: Double
    let rightness: Double
    let frontness: Double
    let backness: Double
}

struct NearestSurfaceHit: Codable, Equatable {
    let point: HandJoint3D
    let normal: HandJoint3D
    let distanceMeters: Double
    let triangleId: Int?
    let regionId: String?
    let regionLabel: String?
    let surface: String
    let surfaceLabel: String
    let confidence: Double
    let contactProfile: SurfaceContactProfile?
}

struct BrainRegionResolution: Codable, Equatable {
    let regionId: String
    let regionLabel: String
    let surface: String
    let surfaceLabel: String
    let confidence: Double
}

protocol BrainSurfaceModel {
    var modelId: String { get }
    var coordinateSpace: String { get }

    func nearestSurfaceHit(to point: HandJoint3D) -> NearestSurfaceHit?
}

protocol BrainRegionResolver {
    func resolveRegion(for hit: NearestSurfaceHit) -> BrainRegionResolution
}

struct MeshTouchDetectionPlan {
    let mode: BrainTouchDetectionMode
    let surfaceModel: BrainSurfaceModel?
    let regionResolver: BrainRegionResolver?

    static let ellipsoidOnly = MeshTouchDetectionPlan(
        mode: .ellipsoid,
        surfaceModel: nil,
        regionResolver: nil
    )
}

// TODO: Implement a real OBJ/STL-backed BrainSurfaceModel after the final
// 3D printed brain model and label mapping format are chosen.
