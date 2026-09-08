import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Ruler mode: connected polyline segments. Each tap commits the next vertex
/// (extending from the last endpoint or from an autolocked pin), and the reticle
/// can snap to any pinpoint (endpoints **and** midpoints) of existing edges.
///
/// Autolock is universal: it applies both when choosing where a new segment *starts*
/// (branching off an existing line) and where it *ends*, so two otherwise independent
/// lines can be joined at a shared pinpoint. A locked endpoint is committed at the pin's
/// exact world position, so the joined lines share one vertex rather than two
/// near-coincident ones.
final class RulerMeasurementMode: MeasurementModeBehavior {
    weak var host: ARSceneView.Coordinator?

    /// Pins this close to the in-flight draft start are excluded while drafting, so the free end
    /// can't lock back onto its own origin (which would only ever produce a zero-length segment).
    private static let draftStartExclusionMeters: Float = 0.005

    init(host: ARSceneView.Coordinator) {
        self.host = host
    }

    func pinCandidates() -> [SIMD3<Float>] {
        guard let host, !host.committedSegments.isEmpty else { return [] }
        let pins = MeasurementSegment.allPinpointWorldPositions(for: host.committedSegments)
        guard let start = host.draftSegmentStart else { return pins }
        return pins.filter { simd_distance($0, start) > Self.draftStartExclusionMeters }
    }

    func resetAutolockBookkeepingIfNeeded() {
        guard let host else { return }
        // Only clear when there is nothing to lock onto. Clearing during a draft (the old rule)
        // would re-trigger the lock haptic every frame now that the free end can autolock too.
        if host.committedSegments.isEmpty {
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
            // If the free end is autolocked, join at the pin's exact position so the two lines
            // share a single vertex (the reticle target already equals the pin, but be explicit).
            let end = host.latestPinAutolockWorld ?? p
            if simd_distance(start, end) > 1e-5 {
                host.committedSegments.append(MeasurementSegment(start: start, end: end))
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
