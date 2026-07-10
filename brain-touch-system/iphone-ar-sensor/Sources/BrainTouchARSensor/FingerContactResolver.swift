import ARKit
import CoreVideo
import Foundation
import simd

enum ContactFinger: String, Codable {
    case index
    case middle
    case ring

    var contactType: String {
        "\(rawValue)_fingertip"
    }
}

struct FingerContactCandidate {
    let finger: ContactFinger
    let tipDepthSample: DepthSampleResult
    let tip3D: HandJoint3D
    let dip3D: HandJoint3D?
    let surfaceHit: NearestSurfaceHit
    let surfaceApproachAlignment: Double?
}

struct FingerContactResolution {
    let indexDepthSample: DepthSampleResult?
    let rawIndexTip3D: HandJoint3D?
    let selected: FingerContactCandidate?

    var nearestSurfaceHit: NearestSurfaceHit? {
        selected?.surfaceHit
    }
}

enum FingerContactResolver {
    static func resolve(
        detection: MediaPipeHandDetection,
        depthData: ARDepthData?,
        depthSource: String,
        capturedImage: CVPixelBuffer,
        camera: ARCamera,
        brainSTLMetadata: BrainSTLMetadata?,
        calibration: BrainCalibration,
        kernelSize: Int = 5
    ) -> FingerContactResolution {
        let specs: [(ContactFinger, MediaPipeHandLandmark, MediaPipeHandLandmark)] = [
            (.index, .indexTip, .indexDIP),
            (.middle, .middleTip, .middleDIP),
            (.ring, .ringTip, .ringDIP)
        ]
        guard let brainSTLMetadata else {
            let indexSample = sample(
                landmark: detection.landmark(.indexTip),
                name: "index_tip",
                depthData: depthData,
                depthSource: depthSource,
                capturedImage: capturedImage,
                kernelSize: kernelSize
            )
            return FingerContactResolution(
                indexDepthSample: indexSample,
                rawIndexTip3D: PointUnprojector.unprojectDepthSample(indexSample, camera: camera),
                selected: nil
            )
        }

        let surfaceModel = SampledBrainSTLSurfaceModel(
            metadata: brainSTLMetadata,
            calibration: calibration
        )
        var indexSample: DepthSampleResult?
        var indexPoint: HandJoint3D?
        var candidates: [FingerContactCandidate] = []

        for (finger, tipLandmark, dipLandmark) in specs {
            let tipSample = sample(
                landmark: detection.landmark(tipLandmark),
                name: "\(finger.rawValue)_tip",
                depthData: depthData,
                depthSource: depthSource,
                capturedImage: capturedImage,
                kernelSize: kernelSize
            )
            let dipSample = sample(
                landmark: detection.landmark(dipLandmark),
                name: "\(finger.rawValue)_dip",
                depthData: depthData,
                depthSource: depthSource,
                capturedImage: capturedImage,
                kernelSize: kernelSize
            )
            guard let tipSample,
                  let tip3D = PointUnprojector.unprojectDepthSample(tipSample, camera: camera) else {
                continue
            }
            if finger == .index {
                indexSample = tipSample
                indexPoint = tip3D
            }
            guard let hit = surfaceModel.nearestSurfaceHit(to: tip3D) else { continue }
            let dip3D = PointUnprojector.unprojectDepthSample(dipSample, camera: camera)
            candidates.append(FingerContactCandidate(
                finger: finger,
                tipDepthSample: tipSample,
                tip3D: tip3D,
                dip3D: dip3D,
                surfaceHit: hit,
                surfaceApproachAlignment: approachAlignment(tip: tip3D, dip: dip3D, normal: hit.normal)
            ))
        }

        return FingerContactResolution(
            indexDepthSample: indexSample,
            rawIndexTip3D: indexPoint,
            selected: candidates.min { $0.surfaceHit.distanceMeters < $1.surfaceHit.distanceMeters }
        )
    }

    private static func sample(
        landmark: HandJoint2D?,
        name: String,
        depthData: ARDepthData?,
        depthSource: String,
        capturedImage: CVPixelBuffer,
        kernelSize: Int
    ) -> DepthSampleResult? {
        DepthSampler.sampleHandJointDepth(
            visionPoint: landmark?.pseudoVisionPointForDepthSampling,
            jointName: name,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: kernelSize
        )
    }

    private static func approachAlignment(
        tip: HandJoint3D,
        dip: HandJoint3D?,
        normal: HandJoint3D
    ) -> Double? {
        guard let dip else { return nil }
        let fingerDirection = SIMD3<Double>(tip.x - dip.x, tip.y - dip.y, tip.z - dip.z)
        let surfaceNormal = SIMD3<Double>(normal.x, normal.y, normal.z)
        guard simd_length_squared(fingerDirection) > 0.0000001,
              simd_length_squared(surfaceNormal) > 0.0000001 else {
            return nil
        }
        let towardSurface = -simd_normalize(fingerDirection)
        return max(0, min(1, simd_dot(towardSurface, simd_normalize(surfaceNormal))))
    }
}
