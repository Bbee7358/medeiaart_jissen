import CoreGraphics
import CoreVideo
import Foundation

#if canImport(MediaPipeTasksVision)
import CoreImage
import MediaPipeTasksVision
import UIKit
#endif

struct MediaPipeHandDetection: Equatable {
    let handDetected: Bool
    let isRetained: Bool
    let landmarks: [HandJoint2D?]
    let confidence: Double
    let inferenceMs: Double?
    let status: String

    static let unavailable = MediaPipeHandDetection(
        handDetected: false,
        isRetained: false,
        landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
        confidence: 0,
        inferenceMs: nil,
        status: "MediaPipeTasksVision not installed"
    )

    func landmark(_ landmark: MediaPipeHandLandmark) -> HandJoint2D? {
        guard landmarks.indices.contains(landmark.rawValue) else { return nil }
        return landmarks[landmark.rawValue]
    }
}

enum MediaPipeHandLandmark: Int, CaseIterable {
    case wrist = 0
    case thumbCMC = 1
    case thumbMCP = 2
    case thumbIP = 3
    case thumbTip = 4
    case indexMCP = 5
    case indexPIP = 6
    case indexDIP = 7
    case indexTip = 8
    case middleMCP = 9
    case middlePIP = 10
    case middleDIP = 11
    case middleTip = 12
    case ringMCP = 13
    case ringPIP = 14
    case ringDIP = 15
    case ringTip = 16
    case littleMCP = 17
    case littlePIP = 18
    case littleDIP = 19
    case littleTip = 20

    static let count = 21
}

enum MediaPipeHandConnections {
    static let pairs: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)
    ]
}

final class MediaPipeHandLandmarker {
    private(set) var status = "initializing"
    private let missingHandGraceMs = 240

    #if canImport(MediaPipeTasksVision)
    private var handLandmarker: HandLandmarker?
    private let ciContext = CIContext()
    private var previousLandmarks: [HandJoint2D?]?
    private var lastDetectedAtMs: Int?
    #endif

    init() {
        #if canImport(MediaPipeTasksVision)
        guard let modelPath = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            status = "missing hand_landmarker.task"
            return
        }

        let options = HandLandmarkerOptions()
        options.runningMode = .video
        options.numHands = 1
        options.minHandDetectionConfidence = 0.35
        options.minHandPresenceConfidence = 0.35
        options.minTrackingConfidence = 0.50
        options.baseOptions.modelAssetPath = modelPath
        options.baseOptions.delegate = .CPU

        do {
            handLandmarker = try HandLandmarker(options: options)
            status = "MediaPipe video tracking ready"
        } catch {
            status = "MediaPipe init error: \(error.localizedDescription)"
        }
        #else
        status = "MediaPipeTasksVision not installed"
        #endif
    }

    func detect(pixelBuffer: CVPixelBuffer) -> MediaPipeHandDetection {
        #if canImport(MediaPipeTasksVision)
        guard let handLandmarker else {
            return MediaPipeHandDetection(
                handDetected: false,
                isRetained: false,
                landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                confidence: 0,
                inferenceMs: nil,
                status: status
            )
        }

        guard let image = makePortraitBackCameraUIImage(from: pixelBuffer) else {
            return MediaPipeHandDetection(
                handDetected: false,
                isRetained: false,
                landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                confidence: 0,
                inferenceMs: nil,
                status: "MediaPipe image conversion failed"
            )
        }

        do {
            let start = Date()
            let timestampMs = Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
            let result = try handLandmarker.detect(
                videoFrame: MPImage(uiImage: image),
                timestampInMilliseconds: timestampMs
            )
            let inferenceMs = Date().timeIntervalSince(start) * 1000
            guard let firstHand = result.landmarks.first else {
                let nowMs = Self.uptimeMilliseconds
                if let previousLandmarks,
                   let lastDetectedAtMs,
                   nowMs - lastDetectedAtMs <= missingHandGraceMs {
                    return MediaPipeHandDetection(
                        handDetected: true,
                        isRetained: true,
                        landmarks: previousLandmarks,
                        confidence: 0.45,
                        inferenceMs: inferenceMs,
                        status: "MediaPipe hand retained"
                    )
                }
                previousLandmarks = nil
                return MediaPipeHandDetection(
                    handDetected: false,
                    isRetained: false,
                    landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                    confidence: 0,
                    inferenceMs: inferenceMs,
                    status: "MediaPipe no hand"
                )
            }

            let rawLandmarks = firstHand.map(Self.normalizedLandmarkToDisplayPoint)
            let displayLandmarks = Self.smoothedLandmarks(
                current: rawLandmarks,
                previous: previousLandmarks
            )
            previousLandmarks = displayLandmarks
            lastDetectedAtMs = Self.uptimeMilliseconds

            return MediaPipeHandDetection(
                handDetected: true,
                isRetained: false,
                landmarks: displayLandmarks,
                confidence: 1.0,
                inferenceMs: inferenceMs,
                status: "MediaPipe detected \(firstHand.count) joints"
            )
        } catch {
            return MediaPipeHandDetection(
                handDetected: false,
                isRetained: false,
                landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                confidence: 0,
                inferenceMs: nil,
                status: "MediaPipe detect error: \(error.localizedDescription)"
            )
        }
        #else
        return .unavailable
        #endif
    }

    #if canImport(MediaPipeTasksVision)
    private func makePortraitBackCameraUIImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let portraitImage = ciImage.oriented(.right)
        guard let cgImage = ciContext.createCGImage(portraitImage, from: portraitImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func normalizedLandmarkToDisplayPoint(_ landmark: NormalizedLandmark) -> HandJoint2D {
        // The pixel buffer is physically rendered into portrait orientation before
        // MediaPipe sees it, so the landmarks are already portrait image coordinates.
        // SwiftUI overlays apply the ARView aspect-fill crop separately.
        HandJoint2D(
            x: min(max(Double(landmark.x), 0), 1),
            y: min(max(Double(landmark.y), 0), 1)
        )
    }

    private static var uptimeMilliseconds: Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func smoothedLandmarks(
        current: [HandJoint2D],
        previous: [HandJoint2D?]?
    ) -> [HandJoint2D?] {
        guard let previous, previous.count == current.count else {
            return current.map(Optional.some)
        }

        return current.enumerated().map { index, point in
            guard let prior = previous[index] else { return point }
            let isFingerTip = [4, 8, 12, 16, 20].contains(index)
            let alpha = isFingerTip ? 0.78 : 0.64
            return HandJoint2D(
                x: prior.x * (1 - alpha) + point.x * alpha,
                y: prior.y * (1 - alpha) + point.y * alpha
            )
        }
    }
    #endif
}

extension HandJoint2D {
    var pseudoVisionPointForDepthSampling: CGPoint {
        CGPoint(x: x, y: 1.0 - y)
    }
}

final class MediaPipeHandDetectionWorker: @unchecked Sendable {
    private struct PixelBufferBox: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    private let queue = DispatchQueue(label: "brain-touch.hand-detection", qos: .userInitiated)
    private let landmarker = MediaPipeHandLandmarker()

    var status: String {
        landmarker.status
    }

    func detect(
        pixelBuffer: CVPixelBuffer,
        completion: @escaping @Sendable (MediaPipeHandDetection) -> Void
    ) {
        let box = PixelBufferBox(value: pixelBuffer)
        queue.async { [landmarker] in
            completion(landmarker.detect(pixelBuffer: box.value))
        }
    }
}
