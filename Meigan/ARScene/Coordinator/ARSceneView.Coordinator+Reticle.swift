//
//  ARSceneView.Coordinator+Reticle.swift
//  Meigan
//
//  Reticle raycasting, pinpoint autolock, hover / haptics, and the crosshair ring mesh.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

// MARK: - Line extension (reticle autolock to segment pinpoints)

/// When a measurement line exists, the reticle can snap to: first mark (left), second mark (right), or segment midpoint — whichever projects closest to the crosshair within `screenSnapRadiusPoints`.
private enum LineExtensionReticleConfig {
    static let screenSnapRadiusPoints: CGFloat = 38
    /// Crosshair this close (points) to the 2D segment between the two marks counts as “on the line”.
    static let lineHoverScreenDistancePoints: CGFloat = 28
}

extension ARSceneView.Coordinator {
    /// While the raycast is momentarily missing (debounce window), hold the reticle on the
    /// current screen-center ray at the last known surface depth. This keeps the ring visually
    /// under the dot instead of parking it at a stale world position while the camera moves.
    func heldReticleTarget(arView: ARView, screenCenter: CGPoint) -> SIMD3<Float>? {
        guard let depth = lastReticleDepthMeters,
              let ray = arView.ray(through: screenCenter) else { return nil }
        return ray.origin + simd_normalize(ray.direction) * depth
    }

    /// A surface under the crosshair: world position plus surface normal, tagged with where it came from.
    struct ReticleSurfaceHit {
        enum Source {
            /// LiDAR scene-reconstruction mesh (RealityKit scene-understanding collision).
            case sceneMesh
            /// A plane ARKit has detected and is tracking (`ARPlaneAnchor` geometry).
            case existingPlane
            /// A plane ARKit estimates from nearby feature points (not yet a tracked anchor).
            case estimatedPlane
        }
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
        let source: Source
    }

    /// When the LiDAR mesh and a plane agree to within this distance, prefer the plane: tracked plane
    /// geometry is refined over time and gives a cleaner position/normal than the voxelised mesh.
    private static let planeOverMeshPreferenceMeters: Float = 0.02
    /// Longest ray we care about; anything beyond is classified `.noSurface` anyway.
    private static let reticleRaycastMaxLengthMeters: Float = 5.0

    /// Nearest-visible-surface raycast under the crosshair.
    ///
    /// Every available source is queried and the hit **closest to the camera** wins — that is, by
    /// definition, the surface the user is actually looking at. The old "existing plane first,
    /// estimated plane only as a fallback" ordering let a large, early-detected plane (the floor)
    /// win even when a closer object sat in front of it: the ray passed straight through the
    /// not-yet-detected top of a box and landed on the floor underneath, so points "phased
    /// through" the object.
    ///
    /// Sources, all tried every frame:
    /// - LiDAR scene mesh via `arView.scene.raycast(mask: .sceneUnderstanding)` — covers object
    ///   tops/sides immediately, long before (or without) ARKit promoting them to planes. Requires
    ///   `sceneUnderstanding.options` to include `.collision` (see `makeUIView`). No-op on non-LiDAR.
    /// - `.existingPlaneGeometry` — tracked plane anchors, bounded by their detected extent.
    /// - `.estimatedPlane` — feature-point estimate; often the first thing to catch a small surface.
    func raycastReticle(
        from center: CGPoint,
        cameraPosition camPos: SIMD3<Float>,
        in arView: ARView
    ) -> ReticleSurfaceHit? {
        var candidates: [ReticleSurfaceHit] = []

        if let ray = arView.ray(through: center) {
            let dir = simd_normalize(ray.direction)
            let meshHits = arView.scene.raycast(
                origin: ray.origin,
                direction: dir,
                length: Self.reticleRaycastMaxLengthMeters,
                query: .nearest,
                mask: .sceneUnderstanding,
                relativeTo: nil
            )
            if let m = meshHits.first {
                let n = simd_length(m.normal) > 1e-6 ? simd_normalize(m.normal) : -dir
                candidates.append(ReticleSurfaceHit(position: m.position, normal: n, source: .sceneMesh))
            }
        }

        func appendPlaneHit(_ target: ARRaycastQuery.Target, as source: ReticleSurfaceHit.Source) {
            guard let q = arView.makeRaycastQuery(from: center, allowing: target, alignment: .any),
                  let h = arView.session.raycast(q).first
            else { return }
            let t = h.worldTransform
            let p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let n = simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
            candidates.append(ReticleSurfaceHit(position: p, normal: n, source: source))
        }
        appendPlaneHit(.existingPlaneGeometry, as: .existingPlane)
        appendPlaneHit(.estimatedPlane, as: .estimatedPlane)

        guard let nearest = candidates.min(by: {
            simd_distance($0.position, camPos) < simd_distance($1.position, camPos)
        }) else { return nil }

        // Mesh and plane agree on the same surface → take the plane's cleaner geometry.
        if nearest.source == .sceneMesh {
            let agreeingPlane = candidates.first { c in
                c.source != .sceneMesh
                    && simd_distance(c.position, nearest.position) <= Self.planeOverMeshPreferenceMeters
            }
            if let agreeingPlane { return agreeingPlane }
        }
        return nearest
    }

    /// Returns the candidate whose screen projection is nearest the crosshair, only if within snap radius.
    static func linePinpointScreenAutolockWorld(
        candidates: [SIMD3<Float>],
        arView: ARView,
        screenCenter: CGPoint
    ) -> SIMD3<Float>? {
        guard !candidates.isEmpty else { return nil }
        let r = LineExtensionReticleConfig.screenSnapRadiusPoints
        var bestWorld: SIMD3<Float>?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for p in candidates {
            guard let sp = arView.project(p) else { continue }
            let d = hypot(sp.x - screenCenter.x, sp.y - screenCenter.y)
            guard d <= r else { continue }
            if d < bestDist {
                bestDist = d
                bestWorld = p
            }
        }
        return bestWorld
    }

    /// Closest committed segment (screen space) to the crosshair; index matches `committedSegments`.
    private static func closestCommittedSegmentScreenIndex(
        segments: [MeasurementSegment],
        arView: ARView,
        screenCenter: CGPoint
    ) -> (index: Int, screenDist: CGFloat)? {
        var bestIdx: Int?
        var bestD: CGFloat = .greatestFiniteMagnitude
        for (i, s) in segments.enumerated() {
            guard s.lengthMeters > 1e-5 else { continue }
            guard let sa = arView.project(s.start), let sb = arView.project(s.end) else { continue }
            let d = distanceFromPointToSegment2D(screenCenter, sa, sb)
            if bestIdx == nil || d < bestD {
                bestD = d
                bestIdx = i
            }
        }
        guard let idx = bestIdx else { return nil }
        return (idx, bestD)
    }

    private static func distanceFromPointToSegment2D(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let apx = p.x - a.x
        let apy = p.y - a.y
        let ab2 = abx * abx + aby * aby
        if ab2 < 1e-8 {
            return hypot(apx, apy)
        }
        var t = (apx * abx + apy * aby) / ab2
        t = min(max(t, 0), 1)
        let cx = a.x + t * abx
        let cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    /// Merge nearly-coincident world points so shared pins render as one marker.
    static func dedupeWorldPositions(_ points: [SIMD3<Float>], tolerance: Float) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(points.count)
        for p in points {
            if !result.contains(where: { simd_distance($0, p) < tolerance }) {
                result.append(p)
            }
        }
        return result
    }

    /// Same style as placing a mark (`ARMeasurementView` uses `.medium`).
    private func triggerMarkStyleHaptic() {
        guard hapticFeedbackEnabled else { return }
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func updatePinAutolockHaptics(pinWorld: SIMD3<Float>?) {
        if let p = pinWorld {
            if let prev = lastAutolockedPinWorld, simd_distance(p, prev) < 0.00015 {
                return
            }
            lastAutolockedPinWorld = p
            triggerMarkStyleHaptic()
        } else {
            lastAutolockedPinWorld = nil
        }
    }

    /// Billboards every committed segment label; hides only the segment the crosshair is on (same mid-dot behavior as before). Flatten: no line mid interaction.
    func updateCommittedSegmentLabelsHoverAndMidDot(
        arView: ARView,
        screenCenter: CGPoint,
        camForLabel: SIMD3<Float>,
        camUp: SIMD3<Float>
    ) {
        guard !committedSegments.isEmpty,
              let container = committedSegmentLabelsContainer
        else {
            lineMidHoverDotEntity?.isEnabled = false
            return
        }

        let children = Array(container.children)
        guard children.count == committedSegments.count else { return }

        let threshold = LineExtensionReticleConfig.lineHoverScreenDistancePoints
        let hoverPick = Self.closestCommittedSegmentScreenIndex(
            segments: committedSegments,
            arView: arView,
            screenCenter: screenCenter
        )
        let hoverIndex = currentMode.applyLineHoverAndMidDot(hoverPick: hoverPick, threshold: threshold)

        for i in 0..<committedSegments.count {
            let seg = committedSegments[i]
            let root = children[i]
            guard seg.lengthMeters > 1e-5 else {
                root.isEnabled = false
                continue
            }
            let hideForHover = (hoverIndex != nil) && i == hoverIndex
            root.isEnabled = !hideForHover
            if hideForHover { continue }

            let labelPos = Self.measurementLabelWorldPosition(
                segmentFrom: seg.start,
                segmentTo: seg.end,
                cameraWorld: camForLabel
            )
            root.position = labelPos
            let s = Self.measurementLabelUniformScaleForFixedScreenSize(
                cameraWorld: camForLabel,
                labelWorldPosition: labelPos
            )
            root.scale = SIMD3<Float>(repeating: s)
            root.orientation = Self.measurementLabelViewAlignedQuaternion(
                labelPosition: labelPos,
                segmentFrom: seg.start,
                segmentTo: seg.end,
                cameraWorld: camForLabel,
                cameraUpWorld: camUp
            )
        }
    }


    // MARK: - Ring mesh generation

    /// Three arc segments with equal gaps (broken circle).
    static func generateRingMesh(innerRadius: Float, outerRadius: Float, arcCount: Int = 3, segmentsPerArc: Int = 16) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let arcSpan: Float = (2.0 * .pi / Float(arcCount)) * 0.75
        let gapSpan: Float = (2.0 * .pi / Float(arcCount)) - arcSpan

        for arc in 0..<arcCount {
            let arcStart = Float(arc) * (arcSpan + gapSpan)
            let baseIndex = UInt32(positions.count)

            for i in 0...segmentsPerArc {
                let t = Float(i) / Float(segmentsPerArc)
                let angle = arcStart + t * arcSpan
                let c = cosf(angle)
                let s = sinf(angle)

                positions.append(SIMD3<Float>(outerRadius * c, 0, outerRadius * s))
                normals.append(SIMD3<Float>(0, 1, 0))

                positions.append(SIMD3<Float>(innerRadius * c, 0, innerRadius * s))
                normals.append(SIMD3<Float>(0, 1, 0))
            }

            for i in 0..<segmentsPerArc {
                let o0 = baseIndex + UInt32(i * 2)
                let i0 = baseIndex + UInt32(i * 2 + 1)
                let o1 = baseIndex + UInt32((i + 1) * 2)
                let i1 = baseIndex + UInt32((i + 1) * 2 + 1)

                indices.append(contentsOf: [o0, i0, o1])
                indices.append(contentsOf: [i0, i1, o1])
            }
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }

    func setupRingEntity(in arView: ARView) {
        guard let mesh = try? Self.generateRingMesh(innerRadius: 0.046, outerRadius: 0.050) else { return }

        var material = UnlitMaterial()
        material.color = .init(tint: .white.withAlphaComponent(0.9))
        // Belt-and-braces with the camera-facing normal flip in the update loop: even if the
        // ring ends up viewed from its -Y side (e.g. mid-blend of `smoothNormal`), never cull it.
        if #available(iOS 18.0, *) {
            material.faceCulling = .none
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.isEnabled = false

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)

        ringEntity = entity
        ringAnchor = anchor
    }
}
