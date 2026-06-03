import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import ImageIO

final class IdentifyMeasurementMode: MeasurementModeBehavior {
    weak var host: ARSceneView.Coordinator?

    private let detector = IdentifyDetector()
    private var lastRunTime: TimeInterval = 0
    private let minInterval: TimeInterval = 0.1   // ~10 Hz

    init(host: ARSceneView.Coordinator) { self.host = host }

    func pinCandidates() -> [SIMD3<Float>] { [] }
    func resetAutolockBookkeepingIfNeeded() {}

    func applyLineHoverAndMidDot(hoverPick: (index: Int, screenDist: CGFloat)?,
                                 threshold: CGFloat) -> Int? {
        host?.lineMidHoverDotEntity?.isEnabled = false
        return nil
    }

    func placeMark(at reticleWorld: SIMD3<Float>) {}   // Identify places nothing

    func updateAfterReticle(reticleWorld: SIMD3<Float>,
                            camWorld: SIMD3<Float>,
                            camUp: SIMD3<Float>) {
        guard let host, let arView = host.arView,
              let frame = arView.session.currentFrame else { return }

        let now = CACurrentMediaTime()
        guard now - lastRunTime >= minInterval else { return }
        lastRunTime = now

        let uiOrientation = Self.interfaceOrientation(in: arView)
        let cgOrientation = Self.cgOrientation(for: uiOrientation)
        let viewport = arView.bounds.size
        let pixelBuffer = frame.capturedImage

        detector.detect(pixelBuffer: pixelBuffer, orientation: cgOrientation) { [weak self] raw in
            guard let self, let host = self.host else { return }
            let mapped = self.mapToView(raw, frame: frame,
                                        orientation: uiOrientation, viewport: viewport)
            DispatchQueue.main.async {
                guard host.currentMode === self else { return }   // still in Identify
                host.identifyDetections = mapped
            }
        }
    }

    // MARK: - Mapping (step 5)

    private func mapToView(_ raw: [RawDetection], frame: ARFrame,
                           orientation: UIInterfaceOrientation,
                           viewport: CGSize) -> [IdentifyDetection] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        let display = frame.displayTransform(for: orientation, viewportSize: viewport)
        return raw.enumerated().map { idx, d in
            // Vision/displayTransform expects bottom-left origin -> flip Y.
            let visionRect = CGRect(x: d.boxNormalized.minX,
                                    y: 1 - d.boxNormalized.maxY,
                                    width: d.boxNormalized.width,
                                    height: d.boxNormalized.height)
            // normalized image space -> normalized viewport space
            let nv = visionRect.applying(display)
            let viewRect = CGRect(x: nv.minX * viewport.width,
                                  y: nv.minY * viewport.height,
                                  width: nv.width * viewport.width,
                                  height: nv.height * viewport.height)
            return IdentifyDetection(id: idx, label: d.label,
                                     confidence: d.confidence, viewRect: viewRect)
        }
    }

    private static func interfaceOrientation(in arView: ARView) -> UIInterfaceOrientation {
        arView.window?.windowScene?.interfaceOrientation
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first
            ?? .portrait
    }

    private static func cgOrientation(for ui: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        // ARFrame.capturedImage is sensor-native (landscape-right). Map per UI orientation.
        switch ui {
        case .portrait:           return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft:      return .down
        case .landscapeRight:     return .up
        default:                  return .right
        }
    }
}