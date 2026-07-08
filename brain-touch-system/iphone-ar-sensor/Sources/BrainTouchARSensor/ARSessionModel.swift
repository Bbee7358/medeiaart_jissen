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
    @Published var depthSampleText = "-"
    @Published var depthConfidenceText = "-"
    @Published var touchStatusText = "-"
    @Published var touchRegionText = "-"
    @Published var touchDistanceText = "-"
    @Published var touchDurationText = "-"
    @Published var calibration: BrainCalibration
    @Published var brainModel: BrainEllipsoidModel
    @Published var brainModelCenterText: String

    private var lastFrameTimestamp: TimeInterval?
    private var lastHandPoseTimestamp: TimeInterval = 0
    private var smoothedFrameRate: Double = 0
    private let handPoseInterval: TimeInterval = 0.15
    private var indexTip3DSmoother = Point3DSmoother(maxSampleCount: 5)
    private let touchDetector: TouchDetector

    override init() {
        let loadedCalibration = BrainCalibrationStore.load()
        self.calibration = loadedCalibration
        self.brainModel = loadedCalibration.model
        self.brainModelCenterText = Self.formatCenter(loadedCalibration.model.center)
        self.touchDetector = TouchDetector(calibration: loadedCalibration)
        super.init()
        self.handPose = makeEmptySnapshot()
    }

    func setBrainModelCenterToCurrentFinger() {
        guard let indexTip3D = handPose.indexTip3D else { return }
        updateCalibration { calibration in
            calibration.centerX = indexTip3D.x
            calibration.centerY = indexTip3D.y
            calibration.centerZ = indexTip3D.z
        }
    }

    func updateCalibration(_ update: (inout BrainCalibration) -> Void) {
        var next = calibration
        update(&next)
        applyCalibration(next, save: true)
    }

    func resetCalibration() {
        applyCalibration(BrainCalibrationStore.reset(), save: false)
    }

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
        let depthSource = frame.smoothedSceneDepth != nil ? "smoothedSceneDepth" : (frame.sceneDepth != nil ? "sceneDepth" : "none")
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera

        Task { @MainActor in
            self.updateFrameMetrics(timestamp: timestamp, hasDepth: hasDepth)
            self.detectHandPoseIfNeeded(
                pixelBuffer: pixelBuffer,
                depthData: depthData,
                depthSource: depthSource,
                camera: camera,
                timestamp: timestamp
            )
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

    func detectHandPoseIfNeeded(
        pixelBuffer: CVPixelBuffer,
        depthData: ARDepthData?,
        depthSource: String,
        camera: ARCamera,
        timestamp: TimeInterval
    ) {
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
                _ = touchDetector.update(indexTip3D: nil, hasDepth: false, timestamp: timestamp)
                updateHandPose(makeEmptySnapshot())
                return
            }

            updateHandPose(makeHandPoseSnapshot(
                from: observation,
                depthData: depthData,
                depthSource: depthSource,
                capturedImage: pixelBuffer,
                camera: camera,
                timestamp: timestamp
            ))
        } catch {
            indexTip3DSmoother.reset()
            _ = touchDetector.update(indexTip3D: nil, hasDepth: false, timestamp: timestamp)
            updateHandPose(makeEmptySnapshot())
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
        touchStatusText = snapshot.touch.isTouching
            ? "touching"
            : (snapshot.touch.isStrongCandidate ? "strong candidate" : (snapshot.touch.isCandidate ? "candidate" : "none"))
        touchRegionText = snapshot.touch.regionLabel
            touchDistanceText = snapshot.touch.distanceCm.map { String(format: "%.1fcm", $0) } ?? "-"
            touchDurationText = String(format: "%.2fs", snapshot.touch.durationSec)
        brainModelCenterText = Self.formatCenter(calibration.model.center)
        if let debug = snapshot.depthDebug,
           let pixel = debug.depthPixel,
           let size = debug.depthMapSize {
            depthSampleText = "px \(pixel.x),\(pixel.y) / \(size.w)x\(size.h)"
            depthConfidenceText = debug.depthConfidenceRaw.map(String.init) ?? "-"
        } else {
            depthSampleText = "-"
            depthConfidenceText = "-"
        }
    }

    func makeHandPoseSnapshot(
        from observation: VNHumanHandPoseObservation,
        depthData: ARDepthData?,
        depthSource: String,
        capturedImage: CVPixelBuffer,
        camera: ARCamera,
        timestamp: TimeInterval
    ) -> HandPoseSnapshot {
        let wrist = recognizedJoint(.wrist, from: observation)
        let thumbTip = recognizedJoint(.thumbTip, from: observation)
        let indexTip = recognizedJoint(.indexTip, from: observation)
        let indexDIP = recognizedJoint(.indexDIP, from: observation)
        let middleTip = recognizedJoint(.middleTip, from: observation)
        let ringTip = recognizedJoint(.ringTip, from: observation)
        let littleTip = recognizedJoint(.littleTip, from: observation)

        let confidence = Double(indexTip?.confidence ?? 0)
        let detected = indexTip != nil && confidence > 0.2
        let depthSample = DepthSampler.sampleIndexFingerDepth(
            indexTipVisionPoint: detected ? indexTip?.visionPoint : nil,
            indexDIPVisionPoint: indexDIP?.visionPoint,
            depthData: depthData,
            capturedImage: capturedImage,
            depthSource: depthSource,
            kernelSize: 7
        )
        let rawIndexTip3D = PointUnprojector.unprojectDepthSample(
            depthSample,
            camera: camera
        )
        let smoothedIndexTip3D = indexTip3DSmoother.append(rawIndexTip3D)
        let touch = touchDetector.update(
            indexTip3D: smoothedIndexTip3D,
            hasDepth: depthSample != nil,
            timestamp: timestamp
        )
        let depthDebug = depthSample.map {
            DepthSamplingDebug(
                depthSample2D: $0.sampleDisplayPoint,
                rawImageNorm: $0.rawImageNormalized,
                depthPixel: $0.depthPixel,
                depthMapSize: $0.depthMapSize,
                capturedImageSize: $0.capturedImageSize,
                visionOrientation: $0.visionOrientation,
                depthConfidenceRaw: $0.depthConfidenceRaw,
                depthSource: $0.depthSource,
                depthStrategy: $0.depthStrategy,
                depthSampleCount: $0.sampleCount
            )
        }

        return HandPoseSnapshot(
            handDetected: detected,
            wrist: wrist?.displayPoint,
            fingerTips: FingerTips2D(
                thumbTip: thumbTip?.displayPoint,
                indexTip: indexTip?.displayPoint,
                middleTip: middleTip?.displayPoint,
                ringTip: ringTip?.displayPoint,
                littleTip: littleTip?.displayPoint
            ),
            indexTipDepthMeters: depthSample?.depthMeters,
            indexTip3D: smoothedIndexTip3D,
            indexTip3DSpace: PointUnprojector.outputCoordinateSpace,
            depthDebug: depthDebug,
            touch: touch,
            calibration: calibration,
            confidence: detected ? max(confidence, touch.confidence) : 0
        )
    }

    func makeEmptySnapshot() -> HandPoseSnapshot {
        HandPoseSnapshot(
            handDetected: false,
            wrist: nil,
            fingerTips: FingerTips2D(
                thumbTip: nil,
                indexTip: nil,
                middleTip: nil,
                ringTip: nil,
                littleTip: nil
            ),
            indexTipDepthMeters: nil,
            indexTip3D: nil,
            indexTip3DSpace: PointUnprojector.outputCoordinateSpace,
            depthDebug: nil,
            touch: .empty,
            calibration: calibration,
            confidence: 0
        )
    }

    func applyCalibration(_ calibration: BrainCalibration, save: Bool) {
        let sanitized = BrainCalibrationStore.sanitized(calibration)
        self.calibration = sanitized
        self.brainModel = sanitized.model
        self.brainModelCenterText = Self.formatCenter(sanitized.model.center)
        self.touchDetector.updateCalibration(sanitized)
        if save {
            BrainCalibrationStore.save(sanitized)
        }
    }

    func recognizedJoint(
        _ jointName: VNHumanHandPoseObservation.JointName,
        from observation: VNHumanHandPoseObservation
    ) -> RecognizedHandJoint? {
        guard let recognizedPoint = try? observation.recognizedPoint(jointName),
              recognizedPoint.confidence > 0 else {
            return nil
        }

        return RecognizedHandJoint(
            displayPoint: DepthSampler.convertVisionPointToNormalizedDisplay(recognizedPoint.location),
            visionPoint: recognizedPoint.location,
            confidence: recognizedPoint.confidence
        )
    }

    func visionImageOrientation() -> CGImagePropertyOrientation {
        // TODO: Update this if the installation uses landscape mounting.
        .right
    }
}

private extension ARSessionModel {
    static func formatCenter(_ center: HandJoint3D) -> String {
        String(format: "x %.3f, y %.3f, z %.3f m", center.x, center.y, center.z)
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

private struct RecognizedHandJoint {
    let displayPoint: HandJoint2D
    let visionPoint: CGPoint
    let confidence: Float
}
