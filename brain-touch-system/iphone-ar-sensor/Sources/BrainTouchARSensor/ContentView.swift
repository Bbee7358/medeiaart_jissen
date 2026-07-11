import SwiftUI

struct ContentView: View {
    @StateObject private var sessionModel = ARSessionModel()
    @StateObject private var webSocketClient = TestEventWebSocketClient()
    @State private var showDebugPanel = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ARViewContainer(sessionModel: sessionModel)
                .ignoresSafeArea()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionModel.touchStatusText)
                        .font(.headline)
                    Text("\(sessionModel.touchRegionText)  \(sessionModel.touchDistanceText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(sessionModel.fpsText) fps")
                    .font(.caption.monospacedDigit())
                Button {
                    showDebugPanel.toggle()
                } label: {
                    Image(systemName: showDebugPanel ? "xmark" : "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(showDebugPanel ? "デバッグを閉じる" : "デバッグを開く")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()

            if showDebugPanel {
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
                    DebugRow(label: "touch mode", value: "stl mesh + index/middle/ring tips")
                    DebugRow(label: "touch status", value: sessionModel.touchStatusText)
                    DebugRow(label: "touch region", value: sessionModel.touchRegionText)
                    DebugRow(label: "touch distance", value: sessionModel.touchDistanceText)
                    DebugRow(label: "touch duration", value: sessionModel.touchDurationText)
                    DebugRow(label: "touch model xyz", value: sessionModel.touchModelPositionText)
                    DebugRow(label: "touch surface mix", value: sessionModel.touchSurfaceMixText)
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
                    DebugRow(label: "auto calibration", value: sessionModel.autoCalibrationText)
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
            }

            if showDebugPanel {
                BrainDepthDetectionOverlay(snapshot: sessionModel.brainDetectionOverlay)
                    .ignoresSafeArea()
            }

            HandSkeletonOverlay(
                skeleton: sessionModel.handPose.skeleton,
                displayTransform: sessionModel.cameraDisplayTransform
            )
                .ignoresSafeArea()

            HandSensorCoverageOverlay(
                skeleton: sessionModel.handPose.skeleton,
                displayTransform: sessionModel.cameraDisplayTransform
            )
                .ignoresSafeArea()

        }
        .onChange(of: sessionModel.handPose) { handPose in
            webSocketClient.updateHandPose(handPose, fps: sessionModel.currentFPS)
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

#Preview {
    ContentView()
}
