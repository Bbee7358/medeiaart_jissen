import Foundation

@MainActor
final class TestEventWebSocketClient: NSObject, ObservableObject {
    @Published var urlString = "ws://192.168.0.10:8787"
    @Published var connectionStatus = "disconnected"
    @Published var lastSentTimestampText = "-"
    @Published var lastSentJSON = ""
    @Published var isConnected = false

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sendTimer: Timer?
    private var connectTimeoutTimer: Timer?
    private var handPose = HandPoseSnapshot.empty

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

        listenForCloseOrError()
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
            let data = try encoder.encode(event)
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

    func listenForCloseOrError() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    self?.listenForCloseOrError()
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

private struct TouchTestEvent: Encodable {
    let version = "0.1.0"
    let source = "iphone-12-pro"
    let timestamp: Int
    let handDetected: Bool
    let isTouching = false
    let region: String? = nil
    let regionLabel: String? = nil
    let surface: String? = nil
    let surfaceLabel: String? = nil
    let contactType = "unknown"
    let distanceCm: Double? = nil
    let durationSec = 0.0
    let confidence: Double
    let debug: TouchTestDebug

    init(timestamp: Int, handPose: HandPoseSnapshot) {
        self.timestamp = timestamp
        self.handDetected = handPose.handDetected
        self.confidence = handPose.confidence
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
    let indexTip3D: TouchPoint3D? = nil
    let depthMeters: Double?
    let fingerTips2D: FingerTips2D
    let fps = 30.0

    init(handPose: HandPoseSnapshot) {
        self.indexTip2D = handPose.fingerTips.indexTip
        self.depthMeters = handPose.indexTipDepthMeters
        self.fingerTips2D = handPose.fingerTips
    }

    enum CodingKeys: String, CodingKey {
        case indexTip2D
        case indexTip3D
        case depthMeters
        case fingerTips2D
        case fps
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeOptionalAsNull(indexTip2D, forKey: .indexTip2D)
        try container.encodeOptionalAsNull(indexTip3D, forKey: .indexTip3D)
        try container.encodeOptionalAsNull(depthMeters, forKey: .depthMeters)
        try container.encode(fingerTips2D, forKey: .fingerTips2D)
        try container.encode(fps, forKey: .fps)
    }
}

private struct TouchPoint3D: Encodable {
    let x: Double
    let y: Double
    let z: Double
}
