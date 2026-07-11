import SwiftUI

struct DebugRow: View {
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

struct HandSkeletonOverlay: View {
    let skeleton: HandSkeleton2D
    let displayTransform: CGAffineTransform

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
                        displayTransform: displayTransform
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
            displayTransform: displayTransform
        )
    }
}

private enum CameraPreviewProjection {
    static func aspectFillPoint(
        _ normalizedPoint: HandJoint2D,
        in viewSize: CGSize,
        displayTransform: CGAffineTransform
    ) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }

        // MediaPipe receives a clockwise-rotated portrait image. Convert its
        // top-left portrait coordinates back to ARKit's native landscape image,
        // then let ARKit describe the exact preview crop for this device.
        let rawImagePoint = CGPoint(
            x: min(max(normalizedPoint.y, 0), 1),
            y: 1.0 - min(max(normalizedPoint.x, 0), 1)
        )
        let viewportPoint = rawImagePoint.applying(displayTransform)

        return CGPoint(
            x: viewportPoint.x * viewSize.width,
            y: viewportPoint.y * viewSize.height
        )
    }
}

struct HandSensorCoverageOverlay: View {
    let skeleton: HandSkeleton2D
    let displayTransform: CGAffineTransform

    var body: some View {
        GeometryReader { proxy in
            if let center = handCenter(in: proxy.size), !visibleBounds(proxy.size).contains(center) {
                let marker = clamped(center, to: visibleBounds(proxy.size))
                ZStack {
                    Circle()
                        .fill(.yellow)
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                }
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 2))
                .position(marker)
                .accessibilityLabel("画面外の手を検出中")
            }
        }
        .allowsHitTesting(false)
    }

    private func handCenter(in size: CGSize) -> CGPoint? {
        let points = skeleton.landmarks.compactMap { landmark -> CGPoint? in
            guard let landmark else { return nil }
            return CameraPreviewProjection.aspectFillPoint(
                landmark,
                in: size,
                displayTransform: displayTransform
            )
        }
        guard !points.isEmpty else { return nil }
        return CGPoint(
            x: points.reduce(0) { $0 + $1.x } / Double(points.count),
            y: points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }

    private func visibleBounds(_ size: CGSize) -> CGRect {
        CGRect(x: 24, y: 72, width: max(0, size.width - 48), height: max(0, size.height - 96))
    }

    private func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

struct BrainDepthDetectionOverlay: View {
    let snapshot: BrainDepthDetectionOverlaySnapshot

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard snapshot.rawDepthCount > 0 || snapshot.candidateCount > 0 else { return }

                drawPoints(
                    snapshot.points,
                    color: .green.opacity(0.62),
                    pointSize: max(2.6, min(size.width, size.height) * 0.0068),
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

}

struct CalibrationStepper: View {
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

struct FingerTipOverlay: View {
    let point: HandJoint2D?
    let displayTransform: CGAffineTransform

    var body: some View {
        GeometryReader { geometry in
            if let point {
                let displayPoint = CameraPreviewProjection.aspectFillPoint(
                    point,
                    in: geometry.size,
                    displayTransform: displayTransform
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
