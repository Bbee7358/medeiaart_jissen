import SwiftUI

struct ContentView: View {
    @StateObject private var sessionModel = ARSessionModel()
    @StateObject private var webSocketClient = TestEventWebSocketClient()

    var body: some View {
        ZStack(alignment: .topLeading) {
            ARViewContainer(sessionModel: sessionModel)
                .ignoresSafeArea()

            FingerTipOverlay(point: sessionModel.handPose.fingerTips.indexTip)
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
                    DebugRow(label: "ellipsoid center", value: sessionModel.brainModelCenterText)

                    Button("Set Ellipsoid Center Here") {
                        sessionModel.setBrainModelCenterToCurrentFinger()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionModel.handPose.indexTip3D == nil)

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
        .onChange(of: sessionModel.handPose) { handPose in
            webSocketClient.updateHandPose(handPose)
        }
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
