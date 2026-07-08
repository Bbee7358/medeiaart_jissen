import ARKit
import Foundation
import Vision

@MainActor
final class ARSessionModel: NSObject, ObservableObject {
    @Published var sessionStatus = "not started"
    @Published var depthStatus = "unavailable"
    @Published var fpsText = "-"
    @Published var timestampText = "-"
    @Published var isDepthAvailable = false
    @Published var handPose = HandPoseSnapshot.empty
    @Published var handDetectedText = "false"
    @Published var indexTipXText = "-"
    @Published var indexTipYText = "-"
    @Published var indexTipDepthText = "-"
    @Published var indexTip3DText = "-"
    @Published var handConfidenceText = "-"

    private var lastFrameTimestamp: TimeInterval?
    private var lastHandPoseTimestamp: TimeInterval = 0
    private var smoothedFrameRate: Double = 0
    private let handPoseInterval: TimeInterval = 0.15
    private var indexTip3DSmoother = Point3DSmoother(maxSampleCount: 5)

    func startSession(on session: ARSession) {
        guard ARWorldTrackingConfiguration.isSupported else {
            sessionStatus = "world tracking unavailable"
            depthStatus = "unavailable"
            isDepthAvailable = false
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        var semantics: ARConfiguration.FrameSemantics = []

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics.insert(.sceneDepth)
        }

        configuration.frameSemantics = semantics
        isDepthAvailable = !semantics.isEmpty
        depthStatus = isDepthAvailable ? "available" : "unavailable"
        sessionStatus = "running"

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
}

extension ARSessionModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let timestamp = frame.timestamp
        let hasDepth = frame.smoothedSceneDepth != nil || frame.sceneDepth != nil
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera

        Task { @MainActor in
            self.updateFrameMetrics(timestamp: timestamp, hasDepth: hasDepth)
            self.detectHandPoseIfNeeded(pixelBuffer: pixelBuffer, depthData: depthData, camera: camera, timestamp: timestamp)
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let status: String

        switch camera.trackingState {
        case .normal:
            status = "running"
        case .notAvailable:
            status = "tracking not available"
        case .limited(let reason):
            status = "limited: \(reason.readableDescription)"
        }

        Task { @MainActor in
            self.sessionStatus = status
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.sessionStatus = "failed: \(error.localizedDescription)"
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.sessionStatus = "interrupted"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.sessionStatus = "interruption ended"
        }
    }
}

private extension ARSessionModel {
    func updateFrameMetrics(timestamp: TimeInterval, hasDepth: Bool) {
        if let lastFrameTimestamp {
            let delta = timestamp - lastFrameTimestamp
            if delta > 0 {
                let instantFps = 1.0 / delta
                smoothedFrameRate = smoothedFrameRate == 0
                    ? instantFps
                    : smoothedFrameRate * 0.85 + instantFps * 0.15
                fpsText = String(format: "%.1f", smoothedFrameRate)
            }
        }

        lastFrameTimestamp = timestamp
        timestampText = String(format: "%.3f", timestamp)
        isDepthAvailable = hasDepth
        depthStatus = hasDepth ? "available" : "unavailable"
    }

    func detectHandPoseIfNeeded(pixelBuffer: CVPixelBuffer, depthData: ARDepthData?, camera: ARCamera, timestamp: TimeInterval) {
        guard timestamp - lastHandPoseTimestamp >= handPoseInterval else { return }
        lastHandPoseTimestamp = timestamp

        do {
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: visionImageOrientation(),
                options: [:]
            )
            try handler.perform([request])

            guard let observation = request.results?.first else {
                indexTip3DSmoother.reset()
                updateHandPose(.empty)
                return
            }

            updateHandPose(makeHandPoseSnapshot(from: observation, depthData: depthData, camera: camera))
        } catch {
            indexTip3DSmoother.reset()
            updateHandPose(.empty)
        }
    }

    func updateHandPose(_ snapshot: HandPoseSnapshot) {
        handPose = snapshot
        handDetectedText = String(snapshot.handDetected)
        indexTipXText = snapshot.fingerTips.indexTip.map { String(format: "%.3f", $0.x) } ?? "-"
        indexTipYText = snapshot.fingerTips.indexTip.map { String(format: "%.3f", $0.y) } ?? "-"
        indexTipDepthText = snapshot.indexTipDepthMeters.map { String(format: "%.2fm", $0) } ?? "-"
        indexTip3DText = snapshot.indexTip3D.map {
            String(format: "x %.3f, y %.3f, z %.3f m", $0.x, $0.y, $0.z)
        } ?? "-"
        handConfidenceText = String(format: "%.2f", snapshot.confidence)
    }

    func makeHandPoseSnapshot(from observation: VNHumanHandPoseObservation, depthData: ARDepthData?, camera: ARCamera) -> HandPoseSnapshot {
        let wrist = recognizedJoint(.wrist, from: observation)
        let thumbTip = recognizedJoint(.thumbTip, from: observation)
        let indexTip = recognizedJoint(.indexTip, from: observation)
        let middleTip = recognizedJoint(.middleTip, from: observation)
        let ringTip = recognizedJoint(.ringTip, from: observation)
        let littleTip = recognizedJoint(.littleTip, from: observation)

        let confidence = Double(indexTip?.confidence ?? 0)
        let detected = indexTip != nil && confidence > 0.2
        let depthMeters = DepthSampler.sampleDepthMeters(
            at: detected ? indexTip?.point : nil,
            from: depthData,
            kernelSize: 5
        )
        let rawIndexTip3D = PointUnprojector.unprojectPoint(
            normalizedPoint: detected ? indexTip?.point : nil,
            depthMeters: depthMeters,
            camera: camera
        )
        let smoothedIndexTip3D = indexTip3DSmoother.append(rawIndexTip3D)

        return HandPoseSnapshot(
            handDetected: detected,
            wrist: wrist?.point,
            fingerTips: FingerTips2D(
                thumbTip: thumbTip?.point,
                indexTip: indexTip?.point,
                middleTip: middleTip?.point,
                ringTip: ringTip?.point,
                littleTip: littleTip?.point
            ),
            indexTipDepthMeters: depthMeters,
            indexTip3D: smoothedIndexTip3D,
            indexTip3DSpace: PointUnprojector.outputCoordinateSpace,
            confidence: detected ? confidence : 0
        )
    }

    func recognizedJoint(
        _ jointName: VNHumanHandPoseObservation.JointName,
        from observation: VNHumanHandPoseObservation
    ) -> (point: HandJoint2D, confidence: Float)? {
        guard let recognizedPoint = try? observation.recognizedPoint(jointName),
              recognizedPoint.confidence > 0 else {
            return nil
        }

        return (
            point: convertVisionPointToNormalizedDisplay(recognizedPoint.location),
            confidence: recognizedPoint.confidence
        )
    }

    func convertVisionPointToNormalizedDisplay(_ point: CGPoint) -> HandJoint2D {
        // TODO: Verify mirror/orientation against the actual mounted iPhone camera view.
        // Vision normalized coordinates use a lower-left origin; the debug UI expects top-left origin.
        HandJoint2D(
            x: Double(point.x),
            y: Double(1.0 - point.y)
        )
    }

    func visionImageOrientation() -> CGImagePropertyOrientation {
        // TODO: Update this if the installation uses landscape mounting.
        .right
    }
}

private extension ARCamera.TrackingState.Reason {
    var readableDescription: String {
        switch self {
        case .initializing:
            return "initializing"
        case .excessiveMotion:
            return "excessive motion"
        case .insufficientFeatures:
            return "insufficient features"
        case .relocalizing:
            return "relocalizing"
        @unknown default:
            return "unknown"
        }
    }
}
