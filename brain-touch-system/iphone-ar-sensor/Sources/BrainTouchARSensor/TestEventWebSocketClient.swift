import Foundation

@MainActor
final class TestEventWebSocketClient: NSObject, ObservableObject {
    @Published var urlString = "ws://WatanabenoMacBook-Air.local:8787"
    @Published var connectionStatus = "disconnected"
    @Published var lastSentTimestampText = "-"
    @Published var lastSentJSON = ""
    @Published var healthCheckStatus = "not checked"
    @Published var lastHealthResponse = ""
    @Published var isConnected = false
    @Published var lastSettingsUpdateText = "-"

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sendTimer: Timer?
    private var connectTimeoutTimer: Timer?
    private var handPose = HandPoseSnapshot.empty
    var onSettingsUpdate: ((RemoteSettingsUpdatePayload) -> Void)?

    func connect() {
        disconnect()

        guard let url = URL(string: urlString), url.scheme == "ws" || url.scheme == "wss" else {
            connectionStatus = "invalid URL"
            return
        }

        connectionStatus = "connecting"
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        urlSession = session
        webSocketTask = task
        task.resume()

        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isConnected else { return }
                self.connectionStatus = "connection timeout: check IP, Wi-Fi, local network permission, and Mac firewall"
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
            }
        }
    }

    func disconnect() {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        sendTimer?.invalidate()
        sendTimer = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        connectionStatus = "disconnected"
    }

    func updateHandPose(_ handPose: HandPoseSnapshot) {
        self.handPose = handPose
    }

    func checkHealth() {
        guard let healthURL = makeHealthURL() else {
            healthCheckStatus = "invalid health URL"
            lastHealthResponse = ""
            return
        }

        healthCheckStatus = "checking \(healthURL.absoluteString)"
        lastHealthResponse = ""

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                if let error {
                    self?.healthCheckStatus = "health error: \(error.localizedDescription)"
                    self?.lastHealthResponse = "\(error)"
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode
                self?.healthCheckStatus = "health ok: HTTP \(statusCode.map(String.init) ?? "unknown")"
                self?.lastHealthResponse = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(empty response)"
            }
        }.resume()
    }
}

extension TestEventWebSocketClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            self.connectTimeoutTimer?.invalidate()
            self.connectTimeoutTimer = nil
            self.isConnected = true
            self.connectionStatus = "connected"
            self.startSending()
            self.listenForMessages()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            self.connectTimeoutTimer?.invalidate()
            self.connectTimeoutTimer = nil
            self.sendTimer?.invalidate()
            self.sendTimer = nil
            self.isConnected = false
            self.connectionStatus = "closed: \(closeCode.readableDescription)"
        }
    }
}

private extension TestEventWebSocketClient {
    func makeHealthURL() -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func startSending() {
        sendTimer?.invalidate()
        sendTestEvent()

        sendTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendTestEvent()
            }
        }
    }

    func sendTestEvent() {
        guard let webSocketTask else { return }

        let event = TouchTestEvent(timestamp: Int(Date().timeIntervalSince1970 * 1000), handPose: handPose)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let envelope = OutgoingTouchEventMessage(type: "touch_event", payload: event)
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                connectionStatus = "encode error"
                return
            }

            webSocketTask.send(.string(json)) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.connectionStatus = "send error: \(error.localizedDescription)"
                        self?.isConnected = false
                        self?.sendTimer?.invalidate()
                        self?.sendTimer = nil
                        return
                    }

                    self?.lastSentJSON = json
                    self?.lastSentTimestampText = Self.formatTimestamp(event.timestamp)
                }
            }
        } catch {
            connectionStatus = "encode error: \(error.localizedDescription)"
        }
    }

    func listenForMessages() {
        guard let webSocketTask else { return }

        webSocketTask.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self?.handleIncomingMessage(message)
                    guard self?.isConnected == true else { return }
                    self?.listenForMessages()
                case .failure(let error):
                    self?.connectTimeoutTimer?.invalidate()
                    self?.connectTimeoutTimer = nil
                    self?.sendTimer?.invalidate()
                    self?.sendTimer = nil
                    self?.isConnected = false
                    self?.connectionStatus = "disconnected: \(error.localizedDescription)"
                }
            }
        }
    }

    func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String

        switch message {
        case .string(let string):
            text = string
        case .data(let data):
            guard let string = String(data: data, encoding: .utf8) else {
                connectionStatus = "ignored binary message"
                return
            }
            text = string
        @unknown default:
            connectionStatus = "ignored unknown message"
            return
        }

        guard let data = text.data(using: .utf8) else { return }

        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(IncomingEnvelope.self, from: data)

            switch envelope.type {
            case "settings_update":
                let settings = try decoder.decode(IncomingSettingsUpdateMessage.self, from: data).payload.sanitized()
                onSettingsUpdate?(settings)
                lastSettingsUpdateText = Self.formatTimestamp(Int(Date().timeIntervalSince1970 * 1000))
            case "ping":
                sendPong()
            case "pong":
                break
            default:
                connectionStatus = "ignored message type: \(envelope.type)"
            }
        } catch {
            connectionStatus = "ignored invalid settings/message: \(error.localizedDescription)"
        }
    }

    func sendPong() {
        guard let webSocketTask else { return }

        let message = PingPongMessage(type: "pong")
        do {
            let data = try JSONEncoder().encode(message)
            guard let json = String(data: data, encoding: .utf8) else { return }
            webSocketTask.send(.string(json)) { _ in }
        } catch {
            connectionStatus = "pong encode error"
        }
    }

    static func formatTimestamp(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return DateFormatter.sentTimestamp.string(from: date)
    }
}

private extension URLSessionWebSocketTask.CloseCode {
    var readableDescription: String {
        switch self {
        case .invalid:
            return "invalid"
        case .normalClosure:
            return "normal closure"
        case .goingAway:
            return "going away"
        case .protocolError:
            return "protocol error"
        case .unsupportedData:
            return "unsupported data"
        case .noStatusReceived:
            return "no status received"
        case .abnormalClosure:
            return "abnormal closure"
        case .invalidFramePayloadData:
            return "invalid frame payload data"
        case .policyViolation:
            return "policy violation"
        case .messageTooBig:
            return "message too big"
        case .mandatoryExtensionMissing:
            return "mandatory extension missing"
        case .internalServerError:
            return "internal server error"
        case .tlsHandshakeFailure:
            return "TLS handshake failure"
        @unknown default:
            return "unknown"
        }
    }
}

private extension DateFormatter {
    static let sentTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

struct RemoteSettingsUpdatePayload: Codable, Equatable {
    let touchThresholdCm: Double
    let strongTouchThresholdCm: Double
    let dwellTimeSec: Double
    let confidenceThreshold: Double
    let smoothingFrames: Int

    func sanitized() -> RemoteSettingsUpdatePayload {
        RemoteSettingsUpdatePayload(
            touchThresholdCm: Self.clamp(touchThresholdCm, min: 0.5, max: 20.0),
            strongTouchThresholdCm: Self.clamp(strongTouchThresholdCm, min: 0.5, max: 20.0),
            dwellTimeSec: Self.clamp(dwellTimeSec, min: 0.0, max: 3.0),
            confidenceThreshold: Self.clamp(confidenceThreshold, min: 0.0, max: 1.0),
            smoothingFrames: Int(Self.clamp(Double(smoothingFrames), min: 1, max: 30))
        )
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        guard value.isFinite else { return minValue }
        return Swift.max(minValue, Swift.min(maxValue, value))
    }
}

private struct IncomingEnvelope: Decodable {
    let type: String
}

private struct IncomingSettingsUpdateMessage: Decodable {
    let type: String
    let payload: RemoteSettingsUpdatePayload
}

private struct OutgoingTouchEventMessage: Encodable {
    let type: String
    let payload: TouchTestEvent
}

private struct PingPongMessage: Encodable {
    let type: String
}

private struct TouchTestEvent: Encodable {
    let version = "0.1.0"
    let source = "iphone-12-pro"
    let timestamp: Int
    let handDetected: Bool
    let isTouching: Bool
    let region: String?
    let regionLabel: String?
    let surface: String?
    let surfaceLabel: String?
    let contactType: String
    let distanceCm: Double?
    let durationSec: Double
    let confidence: Double
    let debug: TouchTestDebug

    init(timestamp: Int, handPose: HandPoseSnapshot) {
        self.timestamp = timestamp
        self.handDetected = handPose.handDetected
        self.isTouching = handPose.touch.isTouching
        self.region = handPose.touch.region
        self.regionLabel = handPose.touch.regionLabel
        self.surface = handPose.touch.surface
        self.surfaceLabel = handPose.touch.surfaceLabel
        self.contactType = handPose.handDetected ? "index_fingertip" : "unknown"
        self.distanceCm = handPose.touch.distanceCm
        self.durationSec = handPose.touch.durationSec
        self.confidence = handPose.touch.isCandidate ? handPose.touch.confidence : handPose.confidence
        self.debug = TouchTestDebug(handPose: handPose)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case source
        case timestamp
        case handDetected
        case isTouching
        case region
        case regionLabel
        case surface
        case surfaceLabel
        case contactType
        case distanceCm
        case durationSec
        case confidence
        case debug
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(source, forKey: .source)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(handDetected, forKey: .handDetected)
        try container.encode(isTouching, forKey: .isTouching)
        try container.encodeOptionalAsNull(region, forKey: .region)
        try container.encodeOptionalAsNull(regionLabel, forKey: .regionLabel)
        try container.encodeOptionalAsNull(surface, forKey: .surface)
        try container.encodeOptionalAsNull(surfaceLabel, forKey: .surfaceLabel)
        try container.encode(contactType, forKey: .contactType)
        try container.encodeOptionalAsNull(distanceCm, forKey: .distanceCm)
        try container.encode(durationSec, forKey: .durationSec)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(debug, forKey: .debug)
    }
}

private struct TouchTestDebug: Encodable {
    let indexTip2D: HandJoint2D?
    let indexTip3D: HandJoint3D?
    let indexTip3DSpace: String
    let depthMeters: Double?
    let handDetectorSource: String
    let handDetectorStatus: String
    let handDetectorInferenceMs: Double?
    let handLandmarks2D: [HandJoint2D?]
    let detectedJointCount: Int
    let fingerTips2D: FingerTips2D
    let depthSample2D: HandJoint2D?
    let rawImageNorm: HandJoint2D?
    let depthPixel: PixelPoint?
    let depthMapSize: PixelSize?
    let capturedImageSize: PixelSize?
    let visionOrientation: String?
    let depthConfidenceRaw: Int?
    let depthSource: String?
    let depthStrategy: String?
    let depthSampleCount: Int?
    let touchCandidate: Bool
    let strongTouchCandidate: Bool
    let fingerSpeedMetersPerSec: Double?
    let calibration: BrainCalibration
    let fps = 30.0

    init(handPose: HandPoseSnapshot) {
        self.indexTip2D = handPose.fingerTips.indexTip
        self.indexTip3D = handPose.indexTip3D
        self.indexTip3DSpace = handPose.indexTip3DSpace
        self.depthMeters = handPose.indexTipDepthMeters
        self.handDetectorSource = handPose.detectorSource
        self.handDetectorStatus = handPose.detectorStatus
        self.handDetectorInferenceMs = handPose.detectorInferenceMs
        self.handLandmarks2D = handPose.skeleton.landmarks
        self.detectedJointCount = handPose.skeleton.detectedJointCount
        self.fingerTips2D = handPose.fingerTips
        self.depthSample2D = handPose.depthDebug?.depthSample2D
        self.rawImageNorm = handPose.depthDebug?.rawImageNorm
        self.depthPixel = handPose.depthDebug?.depthPixel
        self.depthMapSize = handPose.depthDebug?.depthMapSize
        self.capturedImageSize = handPose.depthDebug?.capturedImageSize
        self.visionOrientation = handPose.depthDebug?.visionOrientation
        self.depthConfidenceRaw = handPose.depthDebug?.depthConfidenceRaw
        self.depthSource = handPose.depthDebug?.depthSource
        self.depthStrategy = handPose.depthDebug?.depthStrategy
        self.depthSampleCount = handPose.depthDebug?.depthSampleCount
        self.touchCandidate = handPose.touch.isCandidate
        self.strongTouchCandidate = handPose.touch.isStrongCandidate
        self.fingerSpeedMetersPerSec = handPose.touch.speedMetersPerSec
        self.calibration = handPose.calibration
    }

    enum CodingKeys: String, CodingKey {
        case indexTip2D
        case indexTip3D
        case indexTip3DSpace
        case depthMeters
        case handDetectorSource
        case handDetectorStatus
        case handDetectorInferenceMs
        case handLandmarks2D
        case detectedJointCount
        case fingerTips2D
        case depthSample2D
        case rawImageNorm
        case depthPixel
        case depthMapSize
        case capturedImageSize
        case visionOrientation
        case depthConfidenceRaw
        case depthSource
        case depthStrategy
        case depthSampleCount
        case touchCandidate
        case strongTouchCandidate
        case fingerSpeedMetersPerSec
        case calibration
        case fps
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeOptionalAsNull(indexTip2D, forKey: .indexTip2D)
        try container.encodeOptionalAsNull(indexTip3D, forKey: .indexTip3D)
        try container.encode(indexTip3DSpace, forKey: .indexTip3DSpace)
        try container.encodeOptionalAsNull(depthMeters, forKey: .depthMeters)
        try container.encode(handDetectorSource, forKey: .handDetectorSource)
        try container.encode(handDetectorStatus, forKey: .handDetectorStatus)
        try container.encodeOptionalAsNull(handDetectorInferenceMs, forKey: .handDetectorInferenceMs)
        try container.encode(handLandmarks2D, forKey: .handLandmarks2D)
        try container.encode(detectedJointCount, forKey: .detectedJointCount)
        try container.encode(fingerTips2D, forKey: .fingerTips2D)
        try container.encodeOptionalAsNull(depthSample2D, forKey: .depthSample2D)
        try container.encodeOptionalAsNull(rawImageNorm, forKey: .rawImageNorm)
        try container.encodeOptionalAsNull(depthPixel, forKey: .depthPixel)
        try container.encodeOptionalAsNull(depthMapSize, forKey: .depthMapSize)
        try container.encodeOptionalAsNull(capturedImageSize, forKey: .capturedImageSize)
        try container.encodeOptionalAsNull(visionOrientation, forKey: .visionOrientation)
        try container.encodeOptionalAsNull(depthConfidenceRaw, forKey: .depthConfidenceRaw)
        try container.encodeOptionalAsNull(depthSource, forKey: .depthSource)
        try container.encodeOptionalAsNull(depthStrategy, forKey: .depthStrategy)
        try container.encodeOptionalAsNull(depthSampleCount, forKey: .depthSampleCount)
        try container.encode(touchCandidate, forKey: .touchCandidate)
        try container.encode(strongTouchCandidate, forKey: .strongTouchCandidate)
        try container.encodeOptionalAsNull(fingerSpeedMetersPerSec, forKey: .fingerSpeedMetersPerSec)
        try container.encode(calibration, forKey: .calibration)
        try container.encode(fps, forKey: .fps)
    }
}
