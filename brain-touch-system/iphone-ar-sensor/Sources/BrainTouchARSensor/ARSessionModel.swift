import ARKit
import Foundation

@MainActor
final class ARSessionModel: NSObject, ObservableObject {
    @Published var sessionStatus = "not started"
    @Published var depthStatus = "unavailable"
    @Published var fpsText = "-"
    @Published var timestampText = "-"
    @Published var isDepthAvailable = false
    @Published var handPose = HandPoseSnapshot.empty
    @Published var handDetectorStatusText = "not started"
    @Published var handDetectorSourceText = "mediapipe"
    @Published var handJointCountText = "0/21"
    @Published var handInferenceText = "-"
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
    @Published var lastSettingsUpdateText = "-"
    @Published var depthCalibrationStatusText = "baseline needed"
    @Published var autoCalibrationText = "waiting for stable empty view"
    @Published var depthCalibrationSampleText = "-"
    @Published var depthCalibrationEstimateText = "-"
    @Published var brainDetectionOverlay = BrainDepthDetectionOverlaySnapshot.empty
    @Published var stlStatusText = "loading..."
    @Published var stlResourceText = "-"
    @Published var stlRawSizeText = "-"
    @Published var stlAssumedSizeText = "-"
    @Published var stlScaleText = "-"
    @Published var stlScaledSizeText = "-"
    @Published var stlProjectionText = "-"
    @Published var stlProjectionOverlay = STLProjectionOverlaySnapshot.empty
    @Published var stlNearestDistanceText = "-"
    @Published var stlNearestSurfaceText = "-"

    private var lastFrameTimestamp: TimeInterval?
    private var lastHandPoseTimestamp: TimeInterval = 0
    private var smoothedFrameRate: Double = 0
    private let handPoseInterval: TimeInterval = 0.15
    private var indexTip3DSmoother = Point3DSmoother(maxSampleCount: 5)
    private let touchDetector: TouchDetector
    private var depthCalibrationBaseline: DepthCalibrationBaseline?
    private var pendingDepthCalibrationAction: DepthCalibrationAction?
    private var brainSTLMetadata: BrainSTLMetadata?
    private let handLandmarker = MediaPipeHandLandmarker()
    private var isTrackingNormal = false
    private var stableDepthFrameCount = 0
    private var lastAutoDepthEstimateTimestamp: TimeInterval = 0
    private var hasAutoCapturedBaseline = false
    private var hasAutoAppliedDepthEstimate = false

    override init() {
        let loadedCalibration = BrainCalibrationStore.load()
        self.calibration = loadedCalibration
        self.brainModel = loadedCalibration.model
        self.brainModelCenterText = Self.formatCenter(loadedCalibration.model.center)
        self.touchDetector = TouchDetector(calibration: loadedCalibration)
        super.init()
        self.handDetectorStatusText = handLandmarker.status
        self.handPose = makeEmptySnapshot()
        self.loadBrainSTLMetadata()
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

    func captureEmptyDepthBaseline() {
        pendingDepthCalibrationAction = .captureEmptyBaseline
        depthCalibrationStatusText = "capturing empty baseline..."
    }

    func calibrateBrainFromDepthDifference() {
        guard depthCalibrationBaseline != nil else {
            depthCalibrationStatusText = "capture empty baseline first"
            return
        }

        pendingDepthCalibrationAction = .estimateBrainFromBaseline
        depthCalibrationStatusText = "estimating brain from depth..."
    }

    func applyRemoteSettings(_ settings: RemoteSettingsUpdatePayload) {
        var next = calibration
        next.touchThresholdCm = settings.touchThresholdCm
        next.strongTouchThresholdCm = settings.strongTouchThresholdCm
        next.dwellTimeSeconds = settings.dwellTimeSec
        next.confidenceThreshold = settings.confidenceThreshold
        next.smoothingFrames = settings.smoothingFrames
        applyCalibration(next, save: true)
        lastSettingsUpdateText = DateFormatter.settingsUpdate.string(from: Date())
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
            self.isTrackingNormal = Self.isNormalTracking(camera.trackingState)
            self.updateFrameMetrics(timestamp: timestamp, hasDepth: hasDepth)
            self.processAutoDepthCalibration(depthData: depthData, camera: camera, timestamp: timestamp)
            self.processDepthCalibrationIfNeeded(depthData: depthData, camera: camera)
            self.updateSTLProjection(camera: camera)
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
            self.isTrackingNormal = Self.isNormalTracking(camera.trackingState)
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
        if hasDepth, isTrackingNormal, !handPose.handDetected {
            stableDepthFrameCount += 1
        } else {
            stableDepthFrameCount = 0
        }
    }

    func processAutoDepthCalibration(
        depthData: ARDepthData?,
        camera: ARCamera,
        timestamp: TimeInterval
    ) {
        guard pendingDepthCalibrationAction == nil,
              depthData != nil,
              isTrackingNormal,
              !handPose.handDetected else {
            return
        }

        guard stableDepthFrameCount >= 30 else {
            autoCalibrationText = "waiting for stable empty view"
            return
        }

        if depthCalibrationBaseline == nil {
            do {
                let baseline = try DepthBrainCalibrator.makeBaseline(
                    depthData: depthData,
                    camera: camera,
                    workingRadiusMeters: 0.50
                )
                depthCalibrationBaseline = baseline
                hasAutoCapturedBaseline = true
                autoCalibrationText = "auto baseline captured"
                depthCalibrationStatusText = "auto empty baseline captured"
                depthCalibrationSampleText = String(
                    format: "baseline %d px, %.2fm, r %.0fpx",
                    baseline.sampleCount,
                    baseline.medianDepthMeters,
                    baseline.workingRadiusPixels
                )
            } catch {
                autoCalibrationText = "auto baseline failed"
            }
            return
        }

        guard timestamp - lastAutoDepthEstimateTimestamp >= 2.0,
              let baseline = depthCalibrationBaseline else {
            return
        }

        lastAutoDepthEstimateTimestamp = timestamp
        do {
            let estimate = try DepthBrainCalibrator.estimateBrain(
                depthData: depthData,
                camera: camera,
                baseline: baseline
            )
            applyDepthCalibrationEstimate(
                estimate,
                status: hasAutoAppliedDepthEstimate ? "auto depth calibration updated" : "auto brain calibrated from depth",
                blendWithCurrent: hasAutoAppliedDepthEstimate,
                save: true
            )
            hasAutoAppliedDepthEstimate = true
            autoCalibrationText = hasAutoCapturedBaseline ? "auto baseline + brain active" : "auto brain active"
        } catch {
            autoCalibrationText = "auto waiting for brain candidate"
        }
    }

    func processDepthCalibrationIfNeeded(depthData: ARDepthData?, camera: ARCamera) {
        guard let action = pendingDepthCalibrationAction else { return }
        pendingDepthCalibrationAction = nil

        do {
            switch action {
            case .captureEmptyBaseline:
                let baseline = try DepthBrainCalibrator.makeBaseline(
                    depthData: depthData,
                    camera: camera,
                    workingRadiusMeters: 0.50
                )
                depthCalibrationBaseline = baseline
                depthCalibrationStatusText = "empty baseline captured"
                depthCalibrationSampleText = String(
                    format: "baseline %d px, %.2fm, r %.0fpx",
                    baseline.sampleCount,
                    baseline.medianDepthMeters,
                    baseline.workingRadiusPixels
                )
                depthCalibrationEstimateText = "-"
                brainDetectionOverlay = .empty

            case .estimateBrainFromBaseline:
                guard let baseline = depthCalibrationBaseline else {
                    depthCalibrationStatusText = "capture empty baseline first"
                    return
                }

                let estimate = try DepthBrainCalibrator.estimateBrain(
                    depthData: depthData,
                    camera: camera,
                    baseline: baseline
                )
                applyDepthCalibrationEstimate(
                    estimate,
                    status: "brain calibrated from depth",
                    blendWithCurrent: false,
                    save: true
                )
            }
        } catch let error as DepthBrainCalibrationError {
            depthCalibrationStatusText = "calibration error: \(error.description)"
        } catch {
            depthCalibrationStatusText = "calibration error: \(error.localizedDescription)"
        }
    }

    func applyDepthCalibrationEstimate(
        _ estimate: DepthBrainCalibrationEstimate,
        status: String,
        blendWithCurrent: Bool,
        save: Bool
    ) {
        let blend = blendWithCurrent ? 0.25 : 1.0
        var next = calibration
        next.centerX = blended(current: next.centerX, estimate: estimate.centerWorld.x, alpha: blend)
        next.centerY = blended(current: next.centerY, estimate: estimate.centerWorld.y, alpha: blend)
        next.centerZ = blended(current: next.centerZ, estimate: estimate.centerWorld.z, alpha: blend)
        next.widthMeters = blended(current: next.widthMeters, estimate: estimate.widthMeters, alpha: blend)
        next.depthMeters = blended(current: next.depthMeters, estimate: estimate.depthMeters, alpha: blend)
        next.heightMeters = blended(current: next.heightMeters, estimate: estimate.heightMeters, alpha: blend)
        next.meshRealWidthMeters = blended(current: next.meshRealWidthMeters, estimate: estimate.widthMeters, alpha: blend)
        applyCalibration(next, save: save)
        brainDetectionOverlay = estimate.overlay

        depthCalibrationStatusText = status
        depthCalibrationSampleText = String(
            format: "raw %d/%d, raised %d, weak %d, object %d, max %.1fcm, top %.2fm, base %.2fm",
            estimate.overlay.rawDepthCount,
            estimate.overlay.baselineValidCount,
            estimate.overlay.lowRaisedCount,
            estimate.weakCandidateCount,
            estimate.sampleCount,
            estimate.overlay.maxRaisedHeightMeters * 100,
            estimate.topSurfaceDepthMeters,
            estimate.baselineDepthMeters
        )
        depthCalibrationEstimateText = String(
            format: "w %.2fm, d %.2fm, h %.2fm, center %@, px %d,%d, box %dx%d",
            estimate.widthMeters,
            estimate.depthMeters,
            estimate.heightMeters,
            Self.formatCenter(estimate.centerWorld),
            estimate.centroidPixel.x,
            estimate.centroidPixel.y,
            estimate.bounds.widthPixels,
            estimate.bounds.heightPixels
        )
    }

    func blended(current: Double, estimate: Double, alpha: Double) -> Double {
        current * (1.0 - alpha) + estimate * alpha
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

        let detection = handLandmarker.detect(pixelBuffer: pixelBuffer)
        guard detection.handDetected else {
            indexTip3DSmoother.reset()
            _ = touchDetector.update(indexTip3D: nil, hasDepth: false, timestamp: timestamp)
            updateSTLNearestDebug(indexTip3D: nil)
            updateHandPose(makeEmptySnapshot(detectorStatus: detection.status, inferenceMs: detection.inferenceMs))
            return
        }

        updateHandPose(makeHandPoseSnapshot(
            from: detection,
            depthData: depthData,
            depthSource: depthSource,
            capturedImage: pixelBuffer,
            camera: camera,
            timestamp: timestamp
        ))
    }

    func updateHandPose(_ snapshot: HandPoseSnapshot) {
        handPose = snapshot
        handDetectorSourceText = snapshot.detectorSource
        handDetectorStatusText = snapshot.detectorStatus
        handJointCountText = "\(snapshot.skeleton.detectedJointCount)/\(MediaPipeHandLandmark.count)"
        handInferenceText = snapshot.detectorInferenceMs.map { String(format: "%.1fms", $0) } ?? "-"
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
        from detection: MediaPipeHandDetection,
        depthData: ARDepthData?,
        depthSource: String,
        capturedImage: CVPixelBuffer,
        camera: ARCamera,
        timestamp: TimeInterval
    ) -> HandPoseSnapshot {
        let wrist = detection.landmark(.wrist)
        let thumbTip = detection.landmark(.thumbTip)
        let indexTip = detection.landmark(.indexTip)
        let middleTip = detection.landmark(.middleTip)
        let ringTip = detection.landmark(.ringTip)
        let littleTip = detection.landmark(.littleTip)

        let confidence = detection.confidence
        let detected = indexTip != nil && confidence > 0.2
        let contactResolution = FingerContactResolver.resolve(
            detection: detection,
            depthData: depthData,
            depthSource: depthSource,
            capturedImage: capturedImage,
            camera: camera,
            brainSTLMetadata: brainSTLMetadata,
            calibration: calibration
        )
        let smoothedIndexTip3D = indexTip3DSmoother.append(contactResolution.rawIndexTip3D)
        updateSTLNearestDebug(hit: contactResolution.nearestSurfaceHit, fallbackPoint: smoothedIndexTip3D)
        let touch = touchDetector.update(
            indexTip3D: smoothedIndexTip3D,
            hasDepth: contactResolution.indexDepthSample != nil || contactResolution.nearestSurfaceHit != nil,
            timestamp: timestamp,
            meshHit: contactResolution.nearestSurfaceHit
        )
        let depthDebug = contactResolution.indexDepthSample.map {
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
            wrist: wrist,
            skeleton: HandSkeleton2D(landmarks: detection.landmarks),
            fingerTips: FingerTips2D(
                thumbTip: thumbTip,
                indexTip: indexTip,
                middleTip: middleTip,
                ringTip: ringTip,
                littleTip: littleTip
            ),
            indexTipDepthMeters: contactResolution.indexDepthSample?.depthMeters,
            indexTip3D: smoothedIndexTip3D,
            indexTip3DSpace: PointUnprojector.outputCoordinateSpace,
            depthDebug: depthDebug,
            touch: touch,
            calibration: calibration,
            confidence: detected ? max(confidence, touch.confidence) : 0,
            detectorSource: "mediapipe",
            detectorStatus: detection.status,
            detectorInferenceMs: detection.inferenceMs
        )
    }

    func makeEmptySnapshot(detectorStatus: String = "not started", inferenceMs: Double? = nil) -> HandPoseSnapshot {
        HandPoseSnapshot(
            handDetected: false,
            wrist: nil,
            skeleton: .empty,
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
            confidence: 0,
            detectorSource: "mediapipe",
            detectorStatus: detectorStatus,
            detectorInferenceMs: inferenceMs
        )
    }

    func applyCalibration(_ calibration: BrainCalibration, save: Bool) {
        let sanitized = BrainCalibrationStore.sanitized(calibration)
        self.calibration = sanitized
        self.brainModel = sanitized.model
        self.brainModelCenterText = Self.formatCenter(sanitized.model.center)
        self.indexTip3DSmoother = Point3DSmoother(maxSampleCount: sanitized.smoothingFrames)
        self.touchDetector.updateCalibration(sanitized)
        if save {
            BrainCalibrationStore.save(sanitized)
        }
        updateSTLDebugText()
    }

    func loadBrainSTLMetadata() {
        do {
            let metadata = try BrainSTLMeshLoader.loadBundledMetadata()
            brainSTLMetadata = metadata
            stlStatusText = "loaded"
            updateSTLDebugText()
        } catch let error as BrainSTLMeshLoadError {
            brainSTLMetadata = nil
            stlStatusText = "error: \(error.description)"
        } catch {
            brainSTLMetadata = nil
            stlStatusText = "error: \(error.localizedDescription)"
        }
    }

    func updateSTLDebugText() {
        guard let metadata = brainSTLMetadata else {
            stlResourceText = "-"
            stlRawSizeText = "-"
            stlAssumedSizeText = "-"
            stlScaleText = "-"
            stlScaledSizeText = "-"
            stlProjectionText = "-"
            stlProjectionOverlay = .empty
            stlNearestDistanceText = "-"
            stlNearestSurfaceText = "-"
            return
        }

        let bounds = metadata.boundingBox
        let scale = metadata.scaleForRealWidthMeters(calibration.meshRealWidthMeters)
        let scaled = metadata.scaledSizeMeters(realWidthMeters: calibration.meshRealWidthMeters)
        stlResourceText = "\(metadata.resourceName), \(metadata.triangleCount) tris"
        stlRawSizeText = String(
            format: "%.3f x %.3f x %.3f units",
            bounds.widthUnits,
            bounds.depthUnits,
            bounds.heightUnits
        )
        stlAssumedSizeText = String(
            format: "%.4f x %.4f x %.4f m as mm",
            bounds.widthMetersAssumingMillimeters,
            bounds.depthMetersAssumingMillimeters,
            bounds.heightMetersAssumingMillimeters
        )
        stlScaleText = String(
            format: "%.1fx from real width %.3fm",
            scale,
            calibration.meshRealWidthMeters
        )
        stlScaledSizeText = String(
            format: "%.3f x %.3f x %.3f m, yaw %.1fdeg",
            scaled.width,
            scaled.depth,
            scaled.height,
            calibration.meshYawDegrees
        )
    }

    func updateSTLProjection(camera: ARCamera) {
        let overlay = BrainSTLProjector.makeOverlay(
            metadata: brainSTLMetadata,
            calibration: calibration,
            camera: camera
        )
        stlProjectionOverlay = overlay
        guard overlay.sourceSampleCount > 0 else {
            stlProjectionText = "-"
            return
        }

        stlProjectionText = String(
            format: "%d/%d pts, %@",
            overlay.projectedPointCount,
            overlay.sourceSampleCount,
            overlay.mapping
        )
    }

    func updateSTLNearestDebug(hit: NearestSurfaceHit?, fallbackPoint: HandJoint3D?) {
        if let hit {
            stlNearestDistanceText = String(format: "%.1fmm", hit.distanceMeters * 1000)
            stlNearestSurfaceText = String(
                format: "%@ / %@, conf %.2f",
                hit.surfaceLabel,
                hit.regionLabel ?? "不明",
                hit.confidence
            )
            return
        }

        updateSTLNearestDebug(indexTip3D: fallbackPoint)
    }

    func updateSTLNearestDebug(indexTip3D: HandJoint3D?) {
        guard let metadata = brainSTLMetadata,
              let indexTip3D else {
            stlNearestDistanceText = "-"
            stlNearestSurfaceText = "-"
            return
        }

        let surfaceModel = SampledBrainSTLSurfaceModel(
            metadata: metadata,
            calibration: calibration
        )
        guard let hit = surfaceModel.nearestSurfaceHit(to: indexTip3D) else {
            stlNearestDistanceText = "-"
            stlNearestSurfaceText = "-"
            return
        }

        stlNearestDistanceText = String(format: "%.1fmm", hit.distanceMeters * 1000)
        stlNearestSurfaceText = String(
            format: "%@ / %@, conf %.2f",
            hit.surfaceLabel,
            hit.regionLabel ?? "不明",
            hit.confidence
        )
    }
}

private extension ARSessionModel {
    static func formatCenter(_ center: HandJoint3D) -> String {
        String(format: "x %.3f, y %.3f, z %.3f m", center.x, center.y, center.z)
    }

    static func isNormalTracking(_ trackingState: ARCamera.TrackingState) -> Bool {
        if case .normal = trackingState {
            return true
        }
        return false
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

private enum DepthCalibrationAction {
    case captureEmptyBaseline
    case estimateBrainFromBaseline
}

private extension DateFormatter {
    static let settingsUpdate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
