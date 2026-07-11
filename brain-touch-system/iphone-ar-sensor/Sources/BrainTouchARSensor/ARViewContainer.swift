import ARKit
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var sessionModel: ARSessionModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = sessionModel
        Task { @MainActor in
            sessionModel.startSession(on: arView.session)
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        let orientation = uiView.window?.windowScene?.interfaceOrientation ?? .portrait
        sessionModel.updateViewport(size: uiView.bounds.size, orientation: orientation)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
    }
}
