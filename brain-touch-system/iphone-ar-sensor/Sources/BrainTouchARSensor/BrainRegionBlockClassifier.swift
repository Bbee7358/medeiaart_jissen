import Foundation
import simd

enum BrainRegionBlockClassifier {
    static func classify(
        rawVertex: SIMD3<Float>,
        boundingBox: STLBoundingBox,
        surface: (id: String, label: String),
        normal: SIMD3<Float>
    ) -> (id: String, label: String) {
        let xRatio = normalized(rawVertex.x, min: boundingBox.minX, max: boundingBox.maxX)
        let yRatio = normalized(rawVertex.y, min: boundingBox.minY, max: boundingBox.maxY)
        let zRatio = normalized(rawVertex.z, min: boundingBox.minZ, max: boundingBox.maxZ)
        let distanceToOuterEdge = min(xRatio, 1 - xRatio, yRatio, 1 - yRatio)
        let isOuterBand = distanceToOuterEdge <= 0.18
        let isClearlyTopFacing = surface.id == "top" && normal.y > 0.58
        let isUpperCentralCap = isClearlyTopFacing && !isOuterBand && zRatio >= 0.45

        let layer: (id: String, label: String)
        if isUpperCentralCap {
            layer = ("top", "上段")
        } else {
            layer = ("side_lower", "側面下段")
        }

        let depth: (id: String, label: String)
        if yRatio < 0.34 {
            depth = ("front", "前")
        } else if yRatio < 0.67 {
            depth = ("middle", "中央")
        } else {
            depth = ("back", "後")
        }

        let side: (id: String, label: String)
        if xRatio < 0.50 {
            side = ("left", "左")
        } else {
            side = ("right", "右")
        }

        return (
            "\(layer.id)_\(depth.id)_\(side.id)",
            "\(layer.label)・\(depth.label)\(side.label)"
        )
    }

    private static func normalized(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        let span = max(maxValue - minValue, 0.000001)
        return Swift.max(0, Swift.min(1, (value - minValue) / span))
    }
}
