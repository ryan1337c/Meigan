import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Ruler mode: connected polyline segments. Each tap commits the next vertex
/// (extending from the last endpoint or from an autolocked pin), and the reticle
/// can snap to any pinpoint (endpoints **and** midpoints) of existing edges.
final class RulerMeasurementMode: MeasurementModeBehavior {
    weak var host: ARSceneView.Coordinator?

    init(host: ARSceneView.Coordinator) {
        self.host = host
    }

    func pinCandidates() -> [SIMD3<Float>] {
        guard let host else { return [] }
        if host.draftSegmentStart == nil, !host.committedSegments.isEmpty {
            return MeasurementSegment.allPinpointWorldPositions(for: host.committedSegments)
        }
        return []
    }

    func resetAutolockBookkeepingIfNeeded() {
        guard let host else { return }
        if host.committedSegments.isEmpty || host.draftSegmentStart != nil {
            host.lastAutolockedPinWorld = nil
        }
    }

    func applyLineHoverAndMidDot(
        hoverPick: (index: Int, screenDist: CGFloat)?,
        threshold: CGFloat
    ) -> Int? {
        guard let host else { return nil }
        let onSeg = hoverPick.map { $0.screenDist <= threshold } ?? false
        if onSeg, let hi = hoverPick?.index {
            host.lineMidHoverDotEntity?.position = host.committedSegments[hi].midpoint
            host.lineMidHoverDotEntity?.isEnabled = true
            return hi
        } else {
            host.lineMidHoverDotEntity?.isEnabled = false
            return nil
        }
    }

    func updateAfterReticle(reticleWorld: SIMD3<Float>, camWorld: SIMD3<Float>, camUp: SIMD3<Float>) {
        guard let host else { return }
        if host.draftSegmentStart != nil {
            host.updatePreviewLineAndLabel(reticleWorld: reticleWorld, camWorld: camWorld, camUp: camUp)
        }
    }

    func placeMark(at p: SIMD3<Float>) {
        guard let host else { return }

        if let start = host.draftSegmentStart {
            host.draftSegmentStart = nil
            if simd_distance(start, p) > 1e-5 {
                host.committedSegments.append(MeasurementSegment(start: start, end: p))
            }
        } else {
            if !host.committedSegments.isEmpty {
                if let pin = host.latestPinAutolockWorld {
                    host.draftSegmentStart = pin
                } else {
                    host.draftSegmentStart = p
                }
            } else {
                host.draftSegmentStart = p
            }
        }

        host.refreshMeasurementVisuals()
    }
}
