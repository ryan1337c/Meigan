import SwiftUI
import RealityKit
import ARKit

struct ARSceneView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView{
        let arView = ARView(frame: .zero)

        // Configure AR session
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration)

        // Add coaching overlay
        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingOverlay.session = arView.session
        coachingOverlay.goal = .anyPlane

        coachingOverlay.frame = arView.bounds
        arView.addSubview(coachingOverlay)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // No-op
    }
}

#Preview {
    ARSceneView()
}