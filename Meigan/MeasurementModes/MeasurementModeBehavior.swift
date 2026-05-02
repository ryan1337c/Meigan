import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Mode-specific behavior for measurement interactions inside `ARSceneView`.
///
/// `ARSceneView.Coordinator` owns shared AR state (entities, ARView, session lifecycle,
/// reticle smoothing, raycasting) and delegates mode-specific decisions
/// (pin candidates, placement semantics, per-frame previews) to a concrete
/// `MeasurementModeBehavior`. Modes hold a `weak` reference to the host coordinator
/// and mutate its shared state directly, so swapping behavior on mode change does not
/// require reattaching RealityKit entities or restarting the AR session.
protocol MeasurementModeBehavior: AnyObject {
    /// World-space pin candidates for screen-space autolock (e.g. polyline vertices, midpoints).
    func pinCandidates() -> [SIMD3<Float>]

    /// Mode-specific autolock haptic anchor reset rule, evaluated each frame before raycasting.
    func resetAutolockBookkeepingIfNeeded()

    /// Decide line-hover behavior for the committed segment labels and update the mid-dot entity.
    /// Returns the segment index whose label should be hidden for the hover beat (or `nil` if no hover).
    func applyLineHoverAndMidDot(
        hoverPick: (index: Int, screenDist: CGFloat)?,
        threshold: CGFloat
    ) -> Int?

    /// Per-frame preview update once the reticle world position has been computed.
    func updateAfterReticle(reticleWorld: SIMD3<Float>, camWorld: SIMD3<Float>, camUp: SIMD3<Float>)

    /// Handle a "place mark" action at the given reticle world position.
    func placeMark(at reticleWorld: SIMD3<Float>)

    /// Mode-specific commit-fill rebuild after `refreshMeasurementVisuals`.
    /// Default: no-op.
    func rebuildCommittedFillGeometry()
}

extension MeasurementModeBehavior {
    func rebuildCommittedFillGeometry() {}
}
