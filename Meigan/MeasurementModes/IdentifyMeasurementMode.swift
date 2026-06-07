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

        // 1) Try to match existing tracks (prefer highest IoU)
        for var track in tracks {
            var bestIdx: Int?
            var bestIoU: CGFloat = matchIoUThreshold

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
                updatedTracks.append(track)
                unmatchedDetectionIndices.remove(idx)
            } 
        }

        // 2) New detections → new tracks
        for idx in unmatchedDetectionIndices {
            let det = detections[idx]
            updatedTracks.append(IdentifyTrack(
                id: UUID(),
                label: det.label,
                confidence: det.confidence,
                viewRect: det.viewRect,
            ))
        }

        tracks = updatedTracks

        return tracks.map {
            IdentifyDetection(id: $0.id, label: $0.label,
                            confidence: $0.confidence, viewRect: $0.viewRect)
        }
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

        let debugIndex = raw.indices.max(by: { raw[$0].confidence < raw[$1].confidence })
        return raw.enumerated().map { idx, d in
            let box = d.boxNormalized
            let viewRect = CGRect(
                x: box.minX * displayedWidth + offsetX,
                y: box.minY * displayedHeight + offsetY,
                width: box.width * displayedWidth,
                height: box.height * displayedHeight
            )

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