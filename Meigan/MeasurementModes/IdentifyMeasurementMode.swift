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

    // Grace period to cache the detection results to prevent flickering when the detection results are not available
    private var tracks: [IdentifyTrack] = []
    private let matchIoUThreshold: CGFloat = 0.3
    /// Looser IoU used when matching a coasting track (one that missed recent frames),
    /// so a re-detected object re-attaches to its existing track instead of spawning a new one.
    private let coastingMatchIoUThreshold: CGFloat = 0.1
    /// A coasting track and a fresh detection are treated as the same object when their
    /// centers are within this fraction of the larger box dimension (used to suppress duplicates).
    private let coastingCenterDistanceFactor: CGFloat = 0.75
    /// Number of consecutive missed inference frames a track survives before removal
    /// (~0.3 s at the ~10 Hz detection cadence).
    private let maxMissFrames = 3
    /// A detection is dropped unless at least this fraction of its box area falls inside the
    /// drawable region (viewport minus safe zones, and excluding any off-screen cropped part).
    private let minVisibleFractionInView: CGFloat = 0.5
    /// Extra inset (points) added to the system safe-area insets when defining the drawable
    /// region (status bar / notch / home-indicator chrome).
    private let safeZoneExtraInset: CGFloat = 0
    private var detectionGeneration = 0

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

        // Reset tracks if the previous frame had detections but the current frame does not
        if !tracks.isEmpty, host.identifyDetections.isEmpty {
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
                let displayed = self.updateTracks(with: mapped)
                host.identifyDetections = displayed
            }
        }
    }

    private func updateTracks(with detections: [IdentifyDetection]) -> [IdentifyDetection] {
        var unmatchedDetectionIndices = Set(detections.indices)
        var updatedTracks: [IdentifyTrack] = []
        // Tracks kept this frame without a match (coasting). Used to suppress duplicate
        // boxes when an unmatched detection is plausibly one of these same objects.
        var coastingTracks: [IdentifyTrack] = []

        // 1) Match existing tracks to detections (prefer highest IoU). Coasting tracks
        //    use a looser threshold so a re-detected object re-attaches to its track.
        for var track in tracks {
            let threshold = track.missFrames > 0 ? coastingMatchIoUThreshold : matchIoUThreshold
            var bestIdx: Int?
            var bestIoU: CGFloat = threshold

            for idx in unmatchedDetectionIndices {
                let det = detections[idx]
                guard det.label == track.label else { continue }
                let overlap = iou(track.viewRect, det.viewRect)
                if overlap > bestIoU {
                    bestIoU = overlap
                    bestIdx = idx
                }
            }

            if let idx = bestIdx {
                let det = detections[idx]
                track.label = det.label
                track.confidence = det.confidence
                track.viewRect = det.viewRect
                track.missFrames = 0
                updatedTracks.append(track)
                unmatchedDetectionIndices.remove(idx)
            } else {
                // 2) Unmatched track → coast at its last rect. Drop once it exceeds the grace period.
                track.missFrames += 1
                if track.missFrames <= maxMissFrames {
                    updatedTracks.append(track)
                    coastingTracks.append(track)
                }
            }
        }

        // 3) Unmatched detections → new tracks, unless a coasting track of the same label
        //    could plausibly be the same object (prevents a duplicate box appearing next to
        //    the coasting one when matching narrowly failed in step 1).
        for idx in unmatchedDetectionIndices {
            let det = detections[idx]
            let plausiblyExisting = coastingTracks.contains { track in
                track.label == det.label && couldBeSameObject(track.viewRect, det.viewRect)
            }
            guard !plausiblyExisting else { continue }
            updatedTracks.append(IdentifyTrack(
                id: UUID(),
                label: det.label,
                confidence: det.confidence,
                viewRect: det.viewRect,
                missFrames: 0
            ))
        }

        tracks = updatedTracks

        return tracks.map {
            IdentifyDetection(id: $0.id, label: $0.label,
                            confidence: $0.confidence, viewRect: $0.viewRect)
        }
    }

    /// Looser-than-IoU sameness test used only to suppress duplicate new tracks against a
    /// coasting track: any overlap, or centers within `coastingCenterDistanceFactor` of the
    /// larger box dimension, counts as "could be the same object".
    private func couldBeSameObject(_ a: CGRect, _ b: CGRect) -> Bool {
        if iou(a, b) > 0 { return true }
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        let reference = max(a.width, a.height, b.width, b.height)
        guard reference > 0 else { return false }
        return distance < reference * coastingCenterDistanceFactor
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let interArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    func resetTracks() {
        tracks = []
        detectionGeneration += 1
    }

    // MARK: - Mapping (step 5)

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
        let drawableRect = CGRect(
            x: safeAreaInsets.left,
            y: safeAreaInsets.top,
            width: viewport.width - safeAreaInsets.left - safeAreaInsets.right,
            height: viewport.height - safeAreaInsets.top - safeAreaInsets.bottom
        ).insetBy(dx: safeZoneExtraInset, dy: safeZoneExtraInset)

        let debugIndex = raw.indices.max(by: { raw[$0].confidence < raw[$1].confidence })
        return raw.enumerated().compactMap { idx, d -> IdentifyDetection? in
            let box = d.boxNormalized
            let viewRect = CGRect(
                x: box.minX * displayedWidth + offsetX,
                y: box.minY * displayedHeight + offsetY,
                width: box.width * displayedWidth,
                height: box.height * displayedHeight
            )

            // Drop the detection unless at least `minVisibleFractionInView` of the box lies in
            // the drawable region (covers both safe-zone chrome and off-screen cropped edges).
            let totalArea = viewRect.width * viewRect.height
            let visible = viewRect.intersection(drawableRect)
            let visibleArea = visible.isNull ? 0 : visible.width * visible.height
            guard totalArea > 0, visibleArea / totalArea >= minVisibleFractionInView else { return nil }

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
                                     confidence: d.confidence, viewRect: viewRect)
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