import ARKit
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var sessionModel: ARSessionModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = sessionModel
        context.coordinator.installBrainModel(in: arView, model: sessionModel.brainModel)
        Task { @MainActor in
            sessionModel.startSession(on: arView.session)
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateBrainModel(sessionModel.brainModel)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var anchor: AnchorEntity?
        private var modelEntity: ModelEntity?

        func installBrainModel(in arView: ARView, model: BrainEllipsoidModel) {
            let anchor = AnchorEntity(world: SIMD3<Float>(
                Float(model.center.x),
                Float(model.center.y),
                Float(model.center.z)
            ))

            var material = SimpleMaterial()
            material.color = .init(tint: UIColor.systemTeal.withAlphaComponent(0.28), texture: nil)
            material.roughness = .float(0.8)
            material.metallic = .float(0.0)

            let entity = ModelEntity(
                mesh: .generateSphere(radius: 0.5),
                materials: [material]
            )
            entity.scale = SIMD3<Float>(
                Float(model.widthMeters),
                Float(model.heightMeters),
                Float(model.depthMeters)
            )

            addRegionMarker(
                to: anchor,
                offset: SIMD3<Float>(0, Float(model.radiusY), 0),
                color: .systemYellow
            )
            addRegionMarker(
                to: anchor,
                offset: SIMD3<Float>(-Float(model.radiusX), 0, 0),
                color: .systemBlue
            )
            addRegionMarker(
                to: anchor,
                offset: SIMD3<Float>(Float(model.radiusX), 0, 0),
                color: .systemRed
            )
            addRegionMarker(
                to: anchor,
                offset: SIMD3<Float>(0, 0, -Float(model.radiusZ)),
                color: .systemGreen
            )

            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
            self.anchor = anchor
            self.modelEntity = entity
        }

        func updateBrainModel(_ model: BrainEllipsoidModel) {
            anchor?.position = SIMD3<Float>(
                Float(model.center.x),
                Float(model.center.y),
                Float(model.center.z)
            )
            modelEntity?.scale = SIMD3<Float>(
                Float(model.widthMeters),
                Float(model.heightMeters),
                Float(model.depthMeters)
            )
        }

        private func addRegionMarker(to anchor: AnchorEntity, offset: SIMD3<Float>, color: UIColor) {
            var material = SimpleMaterial()
            material.color = .init(tint: color.withAlphaComponent(0.78), texture: nil)
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.018),
                materials: [material]
            )
            marker.position = offset
            anchor.addChild(marker)
        }
    }
}
