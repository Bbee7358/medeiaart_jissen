import ARKit
import CoreVideo
import Foundation

struct FingerContactResolution {
    let indexDepthSample: DepthSampleResult?
    let rawIndexTip3D: HandJoint3D?
    let nearestSurfaceHit: NearestSurfaceHit?
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
        kernelSize: Int = 7
    ) -> FingerContactResolution {
        let indexTip = detection.landmark(.indexTip)
        let indexDIP = detection.landmark(.indexDIP)
        let middleTip = detection.landmark(.middleTip)
        let middleDIP = detection.landmark(.middleDIP)
        let ringTip = detection.landmark(.ringTip)
        let ringDIP = detection.landmark(.ringDIP)

        let indexDepthSample = DepthSampler.sampleIndexFingerDepth(
            indexTipVisionPoint: indexTip?.pseudoVisionPointForDepthSampling,
            indexDIPVisionPoint: indexDIP?.pseudoVisionPointForDepthSampling,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: kernelSize
        )
        let rawIndexTip3D = PointUnprojector.unprojectDepthSample(
            indexDepthSample,
            camera: camera
        )

        let contactSamples = [
            indexDepthSample,
            sampleFingerContactDepth(
                tip: middleTip,
                dip: middleDIP,
                fingerName: "middle",
                depthData: depthData,
                capturedImage: capturedImage,
                depthSource: depthSource,
                kernelSize: kernelSize
            ),
            sampleFingerContactDepth(
                tip: ringTip,
                dip: ringDIP,
                fingerName: "ring",
                depthData: depthData,
                capturedImage: capturedImage,
                depthSource: depthSource,
                kernelSize: kernelSize
            )
        ]

        let candidates = [rawIndexTip3D] + contactSamples.map {
            PointUnprojector.unprojectDepthSample($0, camera: camera)
        }
        let nearestSurfaceHit = nearestSurfaceHit(
            candidates: candidates,
            brainSTLMetadata: brainSTLMetadata,
            calibration: calibration
        )

        return FingerContactResolution(
            indexDepthSample: indexDepthSample,
            rawIndexTip3D: rawIndexTip3D,
            nearestSurfaceHit: nearestSurfaceHit
        )
    }

    private static func sampleFingerContactDepth(
        tip: HandJoint2D?,
        dip: HandJoint2D?,
        fingerName: String,
        depthData: ARDepthData?,
        capturedImage: CVPixelBuffer,
        depthSource: String,
        kernelSize: Int
    ) -> DepthSampleResult? {
        DepthSampler.sampleFingerContactDepth(
            tipVisionPoint: tip?.pseudoVisionPointForDepthSampling,
            dipVisionPoint: dip?.pseudoVisionPointForDepthSampling,
            fingerName: fingerName,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: kernelSize
        )
    }

    private static func nearestSurfaceHit(
        candidates: [HandJoint3D?],
        brainSTLMetadata: BrainSTLMetadata?,
        calibration: BrainCalibration
    ) -> NearestSurfaceHit? {
        guard let brainSTLMetadata else { return nil }

        let surfaceModel = SampledBrainSTLSurfaceModel(
            metadata: brainSTLMetadata,
            calibration: calibration
        )

        return candidates.compactMap { candidate -> NearestSurfaceHit? in
            guard let candidate else { return nil }
            return surfaceModel.nearestSurfaceHit(to: candidate)
        }
        .min { lhs, rhs in
            lhs.distanceMeters < rhs.distanceMeters
        }
    }
}
