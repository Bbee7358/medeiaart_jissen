import SwiftUI

struct ContentView: View {
    @StateObject private var sessionModel = ARSessionModel()
    @StateObject private var webSocketClient = TestEventWebSocketClient()

    var body: some View {
        ZStack(alignment: .topLeading) {
            ARViewContainer(sessionModel: sessionModel)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Brain Touch AR Sensor")
                        .font(.headline)

                    DebugRow(label: "AR session status", value: sessionModel.sessionStatus)
                    DebugRow(label: "depth", value: sessionModel.depthStatus)
                    DebugRow(label: "current FPS", value: sessionModel.fpsText)
                    DebugRow(label: "current timestamp", value: sessionModel.timestampText)
                    DebugRow(label: "hand detector", value: sessionModel.handDetectorSourceText)
                    DebugRow(label: "detector status", value: sessionModel.handDetectorStatusText)
                    DebugRow(label: "detected joints", value: sessionModel.handJointCountText)
                    DebugRow(label: "hand inference", value: sessionModel.handInferenceText)
                    DebugRow(label: "handDetected", value: sessionModel.handDetectedText)
                    DebugRow(label: "indexTip normalized x", value: sessionModel.indexTipXText)
                    DebugRow(label: "indexTip normalized y", value: sessionModel.indexTipYText)
                    DebugRow(label: "indexTip depth", value: sessionModel.indexTipDepthText)
                    DebugRow(label: "indexTip 3D", value: sessionModel.indexTip3DText)
                    DebugRow(label: "depth sample", value: sessionModel.depthSampleText)
                    DebugRow(label: "depth confidence", value: sessionModel.depthConfidenceText)
                    DebugRow(label: "confidence", value: sessionModel.handConfidenceText)
                    DebugRow(label: "legacy touch mode", value: "ellipsoid")
                    DebugRow(label: "legacy touch status", value: sessionModel.touchStatusText)
                    DebugRow(label: "legacy touch region", value: sessionModel.touchRegionText)
                    DebugRow(label: "legacy touch distance", value: sessionModel.touchDistanceText)
                    DebugRow(label: "legacy touch duration", value: sessionModel.touchDurationText)
                    DebugRow(label: "calibrated model center", value: sessionModel.brainModelCenterText)

                    Divider()
                        .background(.white.opacity(0.28))

                    Text("Calibration")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 10) {
                        Button("Set Center Here") {
                            sessionModel.setBrainModelCenterToCurrentFinger()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sessionModel.handPose.indexTip3D == nil)

                        Button("Reset calibration") {
                            sessionModel.resetCalibration()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 10) {
                        Button("Capture Empty Baseline") {
                            sessionModel.captureEmptyDepthBaseline()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!sessionModel.isDepthAvailable)

                        Button("Calibrate Brain From Depth") {
                            sessionModel.calibrateBrainFromDepthDifference()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!sessionModel.isDepthAvailable)
                    }

                    DebugRow(label: "depth calibration", value: sessionModel.depthCalibrationStatusText)
                    DebugRow(label: "depth calib samples", value: sessionModel.depthCalibrationSampleText)
                    DebugRow(label: "depth calib estimate", value: sessionModel.depthCalibrationEstimateText)
                    DebugRow(label: "raw LiDAR depth points", value: "\(sessionModel.brainDetectionOverlay.rawDepthCount)")
                    DebugRow(label: "raised heat points", value: "\(sessionModel.brainDetectionOverlay.lowRaisedCount)")
                    DebugRow(label: "weak raised points", value: "\(sessionModel.brainDetectionOverlay.weakCandidateCount)")
                    DebugRow(label: "adopted brain points", value: "\(sessionModel.brainDetectionOverlay.candidateCount)")
                    DebugRow(label: "max raised height", value: String(format: "%.1fcm", sessionModel.brainDetectionOverlay.maxRaisedHeightMeters * 100))
                    DebugRow(label: "depth overlay map", value: sessionModel.brainDetectionOverlay.mapping)

                    Divider()
                        .background(.white.opacity(0.28))

                    Text("STL Mesh")
                        .font(.subheadline.weight(.semibold))

                    DebugRow(label: "stl status", value: sessionModel.stlStatusText)
                    DebugRow(label: "stl resource", value: sessionModel.stlResourceText)
                    DebugRow(label: "stl raw size", value: sessionModel.stlRawSizeText)
                    DebugRow(label: "stl mm->m size", value: sessionModel.stlAssumedSizeText)
                    DebugRow(label: "stl scale", value: sessionModel.stlScaleText)
                    DebugRow(label: "stl world size", value: sessionModel.stlScaledSizeText)
                    DebugRow(label: "stl projection", value: sessionModel.stlProjectionText)
                    DebugRow(label: "stl nearest distance", value: sessionModel.stlNearestDistanceText)
                    DebugRow(label: "stl nearest surface", value: sessionModel.stlNearestSurfaceText)

                    CalibrationStepper(
                        label: "brain center x",
                        value: calibrationBinding(\.centerX),
                        range: -2.0...2.0,
                        step: 0.01,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "brain center y",
                        value: calibrationBinding(\.centerY),
                        range: -2.0...2.0,
                        step: 0.01,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "brain center z",
                        value: calibrationBinding(\.centerZ),
                        range: -3.0...0.5,
                        step: 0.01,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "brain width",
                        value: calibrationBinding(\.widthMeters),
                        range: 0.05...1.0,
                        step: 0.01,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "brain depth",
                        value: calibrationBinding(\.depthMeters),
                        range: 0.05...1.0,
                        step: 0.01,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "brain height",
                        value: calibrationBinding(\.heightMeters),
                        range: 0.05...1.0,
                        step: 0.01,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "mesh real width",
                        value: calibrationBinding(\.meshRealWidthMeters),
                        range: 0.03...1.0,
                        step: 0.005,
                        unit: "m"
                    )
                    CalibrationStepper(
                        label: "mesh yaw",
                        value: calibrationBinding(\.meshYawDegrees),
                        range: -180.0...180.0,
                        step: 1.0,
                        unit: "deg"
                    )
                    CalibrationStepper(
                        label: "touch threshold",
                        value: calibrationBinding(\.touchThresholdCm),
                        range: 0.5...20.0,
                        step: 0.5,
                        unit: "cm"
                    )
                    CalibrationStepper(
                        label: "strong touch threshold",
                        value: calibrationBinding(\.strongTouchThresholdCm),
                        range: 0.5...20.0,
                        step: 0.5,
                        unit: "cm"
                    )
                    CalibrationStepper(
                        label: "dwell time",
                        value: calibrationBinding(\.dwellTimeSeconds),
                        range: 0.0...3.0,
                        step: 0.1,
                        unit: "s"
                    )
                    CalibrationStepper(
                        label: "confidence threshold",
                        value: calibrationBinding(\.confidenceThreshold),
                        range: 0.0...1.0,
                        step: 0.05,
                        unit: ""
                    )
                    CalibrationStepper(
                        label: "smoothing frames",
                        value: Binding(
                            get: { Double(sessionModel.calibration.smoothingFrames) },
                            set: { newValue in
                                sessionModel.updateCalibration { calibration in
                                    calibration.smoothingFrames = Int(newValue.rounded())
                                }
                            }
                        ),
                        range: 1.0...30.0,
                        step: 1.0,
                        unit: "frames"
                    )

                    if !sessionModel.isDepthAvailable {
                        Text("LiDAR depth is not available")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                    }

                    Divider()
                        .background(.white.opacity(0.28))

                    Text("PC WebSocket")
                        .font(.subheadline.weight(.semibold))

                    TextField("ws://192.168.0.10:8787", text: $webSocketClient.urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)

                    HStack(spacing: 10) {
                        Button("Connect") {
                            webSocketClient.connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webSocketClient.isConnected)

                        Button("Disconnect") {
                            webSocketClient.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!webSocketClient.isConnected)
                    }

                    Button("Check /health") {
                        webSocketClient.checkHealth()
                    }
                    .buttonStyle(.bordered)

                    DebugRow(label: "WebSocket URL", value: webSocketClient.urlString)
                    DebugRow(label: "health status", value: webSocketClient.healthCheckStatus)
                    DebugRow(label: "connection status", value: webSocketClient.connectionStatus)
                    DebugRow(label: "last settings update", value: sessionModel.lastSettingsUpdateText)
                    DebugRow(label: "last sent timestamp", value: webSocketClient.lastSentTimestampText)

                    Text("last health response")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))

                    ScrollView(.horizontal) {
                        Text(webSocketClient.lastHealthResponse.isEmpty ? "-" : webSocketClient.lastHealthResponse)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)

                    Text("last sent JSON")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))

                    ScrollView(.horizontal) {
                        Text(webSocketClient.lastSentJSON.isEmpty ? "-" : webSocketClient.lastSentJSON)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .padding(16)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .padding()
            }

            BrainDepthDetectionOverlay(snapshot: sessionModel.brainDetectionOverlay)
                .ignoresSafeArea()

            STLProjectionOverlay(snapshot: sessionModel.stlProjectionOverlay)
                .ignoresSafeArea()

            HandSkeletonOverlay(skeleton: sessionModel.handPose.skeleton)
                .ignoresSafeArea()

            FingerTipOverlay(point: sessionModel.handPose.fingerTips.indexTip)
                .ignoresSafeArea()

            DepthDiagnosticBadge(snapshot: sessionModel.brainDetectionOverlay)
                .padding(.top, 52)
                .padding(.horizontal, 10)
        }
        .onChange(of: sessionModel.handPose) { handPose in
            webSocketClient.updateHandPose(handPose)
        }
        .onAppear {
            webSocketClient.onSettingsUpdate = { settings in
                sessionModel.applyRemoteSettings(settings)
            }
        }
    }

    private func calibrationBinding(_ keyPath: WritableKeyPath<BrainCalibration, Double>) -> Binding<Double> {
        Binding(
            get: {
                sessionModel.calibration[keyPath: keyPath]
            },
            set: { newValue in
                sessionModel.updateCalibration { calibration in
                    calibration[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

private struct DebugRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 16)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption.monospacedDigit())
    }
}

private struct STLProjectionOverlay: View {
    let snapshot: STLProjectionOverlaySnapshot

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard snapshot.projectedPointCount > 0 else { return }

                let pointSize = max(2.0, min(size.width, size.height) * 0.006)
                let pointPath = Path { path in
                    for point in snapshot.points {
                        let center = CGPoint(
                            x: point.x * size.width,
                            y: point.y * size.height
                        )
                        path.addEllipse(in: CGRect(
                            x: center.x - pointSize / 2,
                            y: center.y - pointSize / 2,
                            width: pointSize,
                            height: pointSize
                        ))
                    }
                }
                context.fill(pointPath, with: .color(.green.opacity(0.62)))

                let minPoint = CGPoint(
                    x: snapshot.boundsMin.x * size.width,
                    y: snapshot.boundsMin.y * size.height
                )
                let maxPoint = CGPoint(
                    x: snapshot.boundsMax.x * size.width,
                    y: snapshot.boundsMax.y * size.height
                )
                let bounds = CGRect(
                    x: min(minPoint.x, maxPoint.x),
                    y: min(minPoint.y, maxPoint.y),
                    width: abs(maxPoint.x - minPoint.x),
                    height: abs(maxPoint.y - minPoint.y)
                )
                context.stroke(
                    Path(roundedRect: bounds, cornerRadius: 4),
                    with: .color(.orange.opacity(0.95)),
                    lineWidth: 4
                )

                let centroid = CGPoint(
                    x: snapshot.centroid.x * size.width,
                    y: snapshot.centroid.y * size.height
                )
                var cross = Path()
                cross.move(to: CGPoint(x: centroid.x - 10, y: centroid.y))
                cross.addLine(to: CGPoint(x: centroid.x + 10, y: centroid.y))
                cross.move(to: CGPoint(x: centroid.x, y: centroid.y - 10))
                cross.addLine(to: CGPoint(x: centroid.x, y: centroid.y + 10))
                context.stroke(cross, with: .color(.orange), lineWidth: 5)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct HandSkeletonOverlay: View {
    let skeleton: HandSkeleton2D
    private let portraitCameraImageSize = CGSize(width: 1440, height: 1920)

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard skeleton.detectedJointCount > 0 else { return }

                var linePath = Path()
                for connection in MediaPipeHandConnections.pairs {
                    guard let start = point(at: connection.0, size: size),
                          let end = point(at: connection.1, size: size) else {
                        continue
                    }
                    linePath.move(to: start)
                    linePath.addLine(to: end)
                }
                context.stroke(
                    linePath,
                    with: .color(.mint.opacity(0.88)),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )

                for (index, landmark) in skeleton.landmarks.enumerated() {
                    guard let landmark else { continue }
                    let center = CameraPreviewProjection.aspectFillPoint(
                        landmark,
                        in: size,
                        imageSize: portraitCameraImageSize
                    )
                    let isFingerTip = [4, 8, 12, 16, 20].contains(index)
                    let diameter = isFingerTip ? 18.0 : 12.0
                    let rect = CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(isFingerTip ? .yellow.opacity(0.95) : .cyan.opacity(0.92))
                    )
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(.black.opacity(0.72)),
                        lineWidth: 2
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private func point(at index: Int, size: CGSize) -> CGPoint? {
        guard skeleton.landmarks.indices.contains(index),
              let landmark = skeleton.landmarks[index] else {
            return nil
        }

        return CameraPreviewProjection.aspectFillPoint(
            landmark,
            in: size,
            imageSize: portraitCameraImageSize
        )
    }
}

private enum CameraPreviewProjection {
    static func aspectFillPoint(
        _ normalizedPoint: HandJoint2D,
        in viewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        guard viewSize.width > 0,
              viewSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return CGPoint(
                x: min(max(normalizedPoint.x, 0), 1) * viewSize.width,
                y: min(max(normalizedPoint.y, 0), 1) * viewSize.height
            )
        }

        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2

        return CGPoint(
            x: offsetX + min(max(normalizedPoint.x, 0), 1) * scaledWidth,
            y: offsetY + min(max(normalizedPoint.y, 0), 1) * scaledHeight
        )
    }
}

private struct BrainDepthDetectionOverlay: View {
    let snapshot: BrainDepthDetectionOverlaySnapshot

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard snapshot.rawDepthCount > 0 || snapshot.candidateCount > 0 else { return }

                drawPoints(
                    snapshot.rawDepthPoints,
                    color: .white.opacity(0.20),
                    pointSize: max(1.4, min(size.width, size.height) * 0.0038),
                    context: context,
                    size: size
                )
                drawHeatPoints(
                    snapshot.raisedHeatPoints,
                    pointSize: max(3.0, min(size.width, size.height) * 0.008),
                    context: context,
                    size: size
                )
                drawPoints(
                    snapshot.weakPoints,
                    color: .yellow.opacity(0.80),
                    pointSize: max(2.8, min(size.width, size.height) * 0.0075),
                    context: context,
                    size: size
                )
                drawPoints(
                    snapshot.points,
                    color: .cyan.opacity(0.96),
                    pointSize: max(3.2, min(size.width, size.height) * 0.0086),
                    context: context,
                    size: size
                )

                guard snapshot.candidateCount > 0 else { return }

                let minPoint = CGPoint(
                    x: snapshot.boundsMin.x * size.width,
                    y: snapshot.boundsMin.y * size.height
                )
                let maxPoint = CGPoint(
                    x: snapshot.boundsMax.x * size.width,
                    y: snapshot.boundsMax.y * size.height
                )
                let bounds = CGRect(
                    x: min(minPoint.x, maxPoint.x),
                    y: min(minPoint.y, maxPoint.y),
                    width: abs(maxPoint.x - minPoint.x),
                    height: abs(maxPoint.y - minPoint.y)
                )
                context.stroke(
                    Path(roundedRect: bounds, cornerRadius: 4),
                    with: .color(.yellow),
                    lineWidth: 6
                )

                let centroid = CGPoint(
                    x: snapshot.centroid.x * size.width,
                    y: snapshot.centroid.y * size.height
                )
                var cross = Path()
                cross.move(to: CGPoint(x: centroid.x - 12, y: centroid.y))
                cross.addLine(to: CGPoint(x: centroid.x + 12, y: centroid.y))
                cross.move(to: CGPoint(x: centroid.x, y: centroid.y - 12))
                cross.addLine(to: CGPoint(x: centroid.x, y: centroid.y + 12))
                context.stroke(cross, with: .color(.red), lineWidth: 6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private func drawPoints(
        _ points: [HandJoint2D],
        color: Color,
        pointSize: Double,
        context: GraphicsContext,
        size: CGSize
    ) {
        let path = Path { path in
            for point in points {
                let center = CGPoint(
                    x: point.x * size.width,
                    y: point.y * size.height
                )
                path.addEllipse(in: CGRect(
                    x: center.x - pointSize / 2,
                    y: center.y - pointSize / 2,
                    width: pointSize,
                    height: pointSize
                ))
            }
        }
        context.fill(path, with: .color(color))
    }

    private func drawHeatPoints(
        _ points: [DepthDeltaOverlayPoint],
        pointSize: Double,
        context: GraphicsContext,
        size: CGSize
    ) {
        for point in points {
            let normalized = min(1.0, max(0.0, point.heightMeters / 0.10))
            let color = Color(
                red: 0.25 + normalized * 0.75,
                green: 0.05 + normalized * 0.35,
                blue: 1.0 - normalized * 0.95
            ).opacity(0.88)
            let center = CGPoint(
                x: point.point.x * size.width,
                y: point.point.y * size.height
            )
            let rect = CGRect(
                x: center.x - pointSize / 2,
                y: center.y - pointSize / 2,
                width: pointSize,
                height: pointSize
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }
}

private struct DepthDiagnosticBadge: View {
    let snapshot: BrainDepthDetectionOverlaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DEPTH DEBUG v4")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
            Text("white raw  purple/red raised  yellow weak  cyan adopted")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
            Text("green/orange STL projection")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green.opacity(0.95))
            Text(
                String(
                    format: "raw %d  raised %d  weak %d  adopted %d  max %.1fcm",
                    snapshot.rawDepthCount,
                    snapshot.lowRaisedCount,
                    snapshot.weakCandidateCount,
                    snapshot.candidateCount,
                    snapshot.maxRaisedHeightMeters * 100
                )
            )
            .font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.45), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct CalibrationStepper: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 16)
                Text(formattedValue)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .font(.caption)
    }

    private var formattedValue: String {
        if unit.isEmpty {
            return String(format: "%.2f", value)
        }

        return String(format: "%.2f%@", value, unit)
    }
}

private struct FingerTipOverlay: View {
    let point: HandJoint2D?
    private let portraitCameraImageSize = CGSize(width: 1440, height: 1920)

    var body: some View {
        GeometryReader { geometry in
            if let point {
                let displayPoint = CameraPreviewProjection.aspectFillPoint(
                    point,
                    in: geometry.size,
                    imageSize: portraitCameraImageSize
                )

                Circle()
                    .fill(.yellow)
                    .overlay {
                        Circle()
                            .stroke(.black.opacity(0.78), lineWidth: 3)
                    }
                    .frame(width: 28, height: 28)
                    .shadow(color: .yellow.opacity(0.45), radius: 14)
                    .position(displayPoint)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
