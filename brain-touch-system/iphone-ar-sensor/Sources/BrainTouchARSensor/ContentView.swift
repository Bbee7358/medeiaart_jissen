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
                    DebugRow(label: "handDetected", value: sessionModel.handDetectedText)
                    DebugRow(label: "indexTip normalized x", value: sessionModel.indexTipXText)
                    DebugRow(label: "indexTip normalized y", value: sessionModel.indexTipYText)
                    DebugRow(label: "indexTip depth", value: sessionModel.indexTipDepthText)
                    DebugRow(label: "indexTip 3D", value: sessionModel.indexTip3DText)
                    DebugRow(label: "depth sample", value: sessionModel.depthSampleText)
                    DebugRow(label: "depth confidence", value: sessionModel.depthConfidenceText)
                    DebugRow(label: "confidence", value: sessionModel.handConfidenceText)
                    DebugRow(label: "touch status", value: sessionModel.touchStatusText)
                    DebugRow(label: "touch region", value: sessionModel.touchRegionText)
                    DebugRow(label: "touch distance", value: sessionModel.touchDistanceText)
                    DebugRow(label: "touch duration", value: sessionModel.touchDurationText)
                    DebugRow(label: "touch model center", value: sessionModel.brainModelCenterText)

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

    var body: some View {
        GeometryReader { geometry in
            if let point {
                Circle()
                    .fill(.yellow)
                    .overlay {
                        Circle()
                            .stroke(.black.opacity(0.78), lineWidth: 3)
                    }
                    .frame(width: 28, height: 28)
                    .shadow(color: .yellow.opacity(0.45), radius: 14)
                    .position(
                        x: min(max(point.x, 0), 1) * geometry.size.width,
                        y: min(max(point.y, 0), 1) * geometry.size.height
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
