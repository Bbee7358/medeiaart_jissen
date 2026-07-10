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

struct STLProjectionOverlay: View {
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

struct HandSkeletonOverlay: View {
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

struct DepthDiagnosticBadge: View {
    let snapshot: BrainDepthDetectionOverlaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DEPTH DEBUG v4")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
            Text("green adopted  yellow outline  red center")
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
