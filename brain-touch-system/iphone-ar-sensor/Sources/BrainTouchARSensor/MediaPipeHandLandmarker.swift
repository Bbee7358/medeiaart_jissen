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
    let landmarks: [HandJoint2D?]
    let confidence: Double
    let inferenceMs: Double?
    let status: String

    static let unavailable = MediaPipeHandDetection(
        handDetected: false,
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

    #if canImport(MediaPipeTasksVision)
    private var handLandmarker: HandLandmarker?
    private let ciContext = CIContext()
    #endif

    init() {
        #if canImport(MediaPipeTasksVision)
        guard let modelPath = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            status = "missing hand_landmarker.task"
            return
        }

        let options = HandLandmarkerOptions()
        options.runningMode = .image
        options.numHands = 1
        options.minHandDetectionConfidence = 0.45
        options.minHandPresenceConfidence = 0.45
        options.minTrackingConfidence = 0.45
        options.baseOptions.modelAssetPath = modelPath
        options.baseOptions.delegate = .CPU

        do {
            handLandmarker = try HandLandmarker(options: options)
            status = "MediaPipe ready"
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
                landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                confidence: 0,
                inferenceMs: nil,
                status: status
            )
        }

        guard let image = makePortraitBackCameraUIImage(from: pixelBuffer) else {
            return MediaPipeHandDetection(
                handDetected: false,
                landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                confidence: 0,
                inferenceMs: nil,
                status: "MediaPipe image conversion failed"
            )
        }

        do {
            let start = Date()
            let result = try handLandmarker.detect(image: MPImage(uiImage: image))
            let inferenceMs = Date().timeIntervalSince(start) * 1000
            guard let firstHand = result.landmarks.first else {
                return MediaPipeHandDetection(
                    handDetected: false,
                    landmarks: Array(repeating: nil, count: MediaPipeHandLandmark.count),
                    confidence: 0,
                    inferenceMs: inferenceMs,
                    status: "MediaPipe no hand"
                )
            }

            let displayLandmarks = firstHand.map(Self.normalizedLandmarkToDisplayPoint)

            return MediaPipeHandDetection(
                handDetected: true,
                landmarks: displayLandmarks,
                confidence: 1.0,
                inferenceMs: inferenceMs,
                status: "MediaPipe detected \(firstHand.count) joints"
            )
        } catch {
            return MediaPipeHandDetection(
                handDetected: false,
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
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }

    private static func normalizedLandmarkToDisplayPoint(_ landmark: NormalizedLandmark) -> HandJoint2D {
        // MediaPipe sample apps map .right camera frames with x = 1 - y, y = x.
        // This matches the portrait back-camera preview used by the AR debug view.
        HandJoint2D(
            x: min(max(1.0 - Double(landmark.y), 0), 1),
            y: min(max(Double(landmark.x), 0), 1)
        )
    }
    #endif
}

extension HandJoint2D {
    var pseudoVisionPointForDepthSampling: CGPoint {
        CGPoint(x: x, y: 1.0 - y)
    }
}
