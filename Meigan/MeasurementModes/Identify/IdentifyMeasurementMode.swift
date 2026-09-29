import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import ImageIO
import OSLog

final class IdentifyMeasurementMode: MeasurementModeBehavior {
    weak var host: ARSceneView.Coordinator?

    private let detector = IdentifyDetector()
    private var lastRunTime: TimeInterval = 0
    private let minInterval: TimeInterval = 0.1   // ~10 Hz
    private var pipelineDebugFrameID = 0

    private let tracker = IdentifyTracker()
    /// Whether the last published list was non-empty; if the overlay is then cleared externally
    /// (e.g. Clear button), tracks are reset. Tentative tracks alone never count as published.
    private var hasPublishedDetections = false
    /// Extra inset (points) added to the system safe-area insets when defining the drawable
    /// region (status bar / notch / home-indicator chrome).
    private let safeZoneExtraInset: CGFloat = 0
    private var detectionGeneration = 0

    /// Candidates fed to the tracker per frame; larger than the display limit so lower-ranked
    /// objects can still sustain their tracks.
    private let maxTrackedDetections = 15
    private let maxDisplayedDetections = 10

    init(host: ARSceneView.Coordinator) {
        self.host = host
        detector.prepare()
    }

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

        // Reset tracks if detections were published but have since been cleared elsewhere
        if hasPublishedDetections, host.identifyDetections.isEmpty {
            resetTracks()
        }

        let now = CACurrentMediaTime()
        guard now - lastRunTime >= minInterval else { return }
        lastRunTime = now

        let uiOrientation = Self.interfaceOrientation(in: arView)
        let cgOrientation = Self.cgOrientation(for: uiOrientation)
        let viewport = arView.bounds.size
        // Read on the main/scene-update thread; passed into the background mapping closure.
        let safeAreaInsets = arView.safeAreaInsets
        let pixelBuffer = frame.capturedImage
        pipelineDebugFrameID += 1
        let debugFrameID = pipelineDebugFrameID

        let generation = detectionGeneration
        let camWorldForScoring = camWorld
        detector.detect(
            pixelBuffer: pixelBuffer,
            orientation: cgOrientation,
            debugFrameID: debugFrameID
        ) { [weak self] raw in
            guard let self, let host = self.host else { return }
            let mapped = self.mapToView(
                raw,
                frame: frame,
                orientation: uiOrientation,
                viewport: viewport,
                safeAreaInsets: safeAreaInsets,
                debugFrameID: debugFrameID
            )
            DispatchQueue.main.async {
                guard generation == self.detectionGeneration else { return }
                guard host.currentMode === self, !host.isCoachingActive else { return }   // still in Identify

                let drawableRect = Self.drawableRect(
                    viewport: viewport,
                    safeAreaInsets: safeAreaInsets,
                    extraInset: self.safeZoneExtraInset
                )

                // Dedupe before scoring so suppressed boxes don't cost a raycast.
                let scored = self.applyScores(
                    to: self.tracker.suppressOverlaps(mapped),
                    drawableRect: drawableRect,
                    camWorld: camWorldForScoring,
                    arView: arView
                )

                let topScored = self.topDetections(scored, limit: self.maxTrackedDetections)

                let displayed = self.topDetections(
                    self.tracker.update(with: topScored),
                    limit: self.maxDisplayedDetections
                )
                host.identifyDetections = displayed
                self.hasPublishedDetections = !displayed.isEmpty
            }
        }
    }

    // Drawable region = viewport minus the system safe-area insets (status bar / notch /
    // home indicator chrome), shrunk further by `safeZoneExtraInset`. The portion of a box
    // inside this region is what's actually visible to the user.
    private static func drawableRect(
        viewport: CGSize,
        safeAreaInsets: UIEdgeInsets,
        extraInset: CGFloat
    ) -> CGRect {
        CGRect(
            x: safeAreaInsets.left,
            y: safeAreaInsets.top,
            width: viewport.width - safeAreaInsets.left - safeAreaInsets.right,
            height: viewport.height - safeAreaInsets.top - safeAreaInsets.bottom
        ).insetBy(dx: extraInset, dy: extraInset)
    }

    // Distance from camera frame to target in meters.
    private func raycastDistance(
        from screenPoint: CGPoint,
        camWorld: SIMD3<Float>,
        arView: ARView
    ) -> Float? {
        let query: ARRaycastQuery?
        if let q = arView.makeRaycastQuery(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any) {
            query = q
        } else {
            query = arView.makeRaycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
        }
        guard let query, let hit = arView.session.raycast(query).first else { return nil }
        let hitPos = SIMD3<Float>(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )
        return simd_distance(hitPos, camWorld)
    }

    private func applyScores(
        to detections: [IdentifyDetection],
        drawableRect: CGRect,
        camWorld: SIMD3<Float>,
        arView: ARView
    ) -> [IdentifyDetection] {
        detections.map { det in
            let centrality = IdentifyScoring.centrality(viewRect: det.viewRect, drawableRect: drawableRect)
            let proximity: CGFloat
            if let meters = raycastDistance(
                from: CGPoint(x: det.viewRect.midX, y: det.viewRect.midY),
                camWorld: camWorld,
                arView: arView
            ) {
                proximity = IdentifyScoring.proximity(distanceMeters: meters)
            } else {
                proximity = 0
            }
            let score = IdentifyScoring.score(
                confidence: det.confidence,
                centrality: centrality,
                proximity: proximity
            )
            return IdentifyDetection(
                id: det.id,
                label: det.label,
                confidence: det.confidence,
                viewRect: det.viewRect,
                centralityNormalized: centrality,
                proximityNormalized: proximity,
                score: score
            )
        }
    }

    private func topDetections(_ detections: [IdentifyDetection], limit: Int) -> [IdentifyDetection] {
        return detections
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.id.uuidString < $1.id.uuidString // stable tie breaking
            }
            .prefix(limit)
            .map { $0 }
    }

    func resetTracks() {
        tracker.reset()
        hasPublishedDetections = false
        detectionGeneration += 1
    }

    // MARK: - Mapping

    /// `boxNormalized` is already in upright (oriented) image space, which shares the
    /// viewport's orientation, so there is no rotation to apply — only the aspect-fill
    /// scale + crop that `ARView` uses to render the camera feed. Applying
    /// `displayTransform` here re-rotated the box and swapped its width/height; mapping
    /// directly in oriented space preserves the detection's aspect ratio.
    private func mapToView(
        _ raw: [RawDetection],
        frame: ARFrame,
        orientation: UIInterfaceOrientation,
        viewport: CGSize,
        safeAreaInsets: UIEdgeInsets,
        debugFrameID: Int
    ) -> [IdentifyDetection] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }

        let orientedSize = Self.orientedImageSize(
            of: frame.capturedImage,
            orientation: orientation
        )
        guard orientedSize.width > 0, orientedSize.height > 0 else { return [] }

        // ARView renders the camera as aspect-fill: scale so the image covers the
        // viewport, then center (cropping the overflow on the longer axis).
        let scale = max(viewport.width / orientedSize.width,
                        viewport.height / orientedSize.height)
        let displayedWidth = orientedSize.width * scale
        let displayedHeight = orientedSize.height * scale
        let offsetX = (viewport.width - displayedWidth) / 2
        let offsetY = (viewport.height - displayedHeight) / 2

        // Drawable region = viewport minus the system safe-area insets (status bar / notch /
        // home indicator chrome), shrunk further by `safeZoneExtraInset`. The portion of a box
        // inside this region is what's actually visible to the user.
        let drawableRect = Self.drawableRect(
            viewport: viewport,
            safeAreaInsets: safeAreaInsets,
            extraInset: safeZoneExtraInset
        )

        let debugIndex = raw.indices.max(by: { raw[$0].confidence < raw[$1].confidence })
        return raw.enumerated().compactMap { idx, d -> IdentifyDetection? in
            let box = d.boxNormalized
            let viewRect = CGRect(
                x: box.minX * displayedWidth + offsetX,
                y: box.minY * displayedHeight + offsetY,
                width: box.width * displayedWidth,
                height: box.height * displayedHeight
            )

            // Drop any box that isn't entirely inside the drawable region: a partly off-screen or
            // chrome-covered box means the object isn't fully in view.
            guard !viewRect.isEmpty, drawableRect.contains(viewRect) else { return nil }

            #if DEBUG
            if idx == debugIndex {
                IdentifyPipelineDebug.log.notice(
                    """
                    frame=\(debugFrameID, privacy: .public) \(d.label, privacy: .public) conf=\(d.confidence, privacy: .public)
                    3 viewRect: x=\(viewRect.minX, privacy: .public) y=\(viewRect.minY, privacy: .public) w=\(viewRect.width, privacy: .public) h=\(viewRect.height, privacy: .public) viewport=\(viewport.width, privacy: .public)x\(viewport.height, privacy: .public)
                    """
                )
            }
            #endif

            return IdentifyDetection(id: UUID(), label: d.label,
                                     confidence: d.confidence, viewRect: viewRect,
                                     centralityNormalized: 0, proximityNormalized: 0, score: 0)
        }
    }

    /// Upright image dimensions for the given interface orientation. `capturedImage`
    /// is sensor-native (landscape), so portrait orientations swap width/height.
    private static func orientedImageSize(
        of pixelBuffer: CVPixelBuffer,
        orientation: UIInterfaceOrientation
    ) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        switch orientation {
        case .portrait, .portraitUpsideDown:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
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
