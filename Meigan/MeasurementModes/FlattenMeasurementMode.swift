import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import OSLog

/// Debug placement / token sync; filter Console by subsystem or category `ARPlacement`.
private let arPlacementLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

/// Flatten mode: up to 4 corner points form a triangle (3 corners) or quad (4 corners) with
/// translucent fill. Locking onto a placed corner selects it for re-adjustment on the next tap.
/// The reticle snaps only to corners (not segment midpoints) plus the in-flight draft start.
final class FlattenMeasurementMode: MeasurementModeBehavior {
    weak var host: ARSceneView.Coordinator?

    init(host: ARSceneView.Coordinator) {
        self.host = host
    }

    func pinCandidates() -> [SIMD3<Float>] {
        guard let host else { return [] }
        var pins = MeasurementSegment.endpointOnlyPinpointWorldPositions(for: host.committedSegments)
        if let draft = host.draftSegmentStart {
            pins.append(draft)
        }
        return ARSceneView.Coordinator.dedupeWorldPositions(pins, tolerance: 0.005)
    }

    func resetAutolockBookkeepingIfNeeded() {
        guard let host else { return }
        if host.committedSegments.isEmpty && host.draftSegmentStart == nil {
            host.lastAutolockedPinWorld = nil
        }
    }

    func applyLineHoverAndMidDot(
        hoverPick: (index: Int, screenDist: CGFloat)?,
        threshold: CGFloat
    ) -> Int? {
        host?.lineMidHoverDotEntity?.isEnabled = false
        return nil
    }

    func updateAfterReticle(reticleWorld: SIMD3<Float>, camWorld: SIMD3<Float>, camUp: SIMD3<Float>) {
        updateFlattenDraftPreview(reticleWorld: reticleWorld)
        updateFlattenFillPreview(hoverWorld: reticleWorld)
    }

    func placeMark(at p: SIMD3<Float>) {
        guard let host else { return }

        if let adjustingIndex = host.flattenAdjustingPointIndex {
            guard host.latestPinAutolockWorld == nil else {
                arPlacementLog.notice("placeFlattenMarkAtReticle: ABORT adjusted corner target is locked to an existing corner")
                host.showPlacementWarning("Move to a valid surface before updating this corner.")
                return
            }
            updateFlattenPoint(at: adjustingIndex, to: p)
            host.flattenAdjustingPointIndex = nil
            host.refreshMeasurementVisuals()
            return
        }

        if let pin = host.latestPinAutolockWorld {
            guard let pinIndex = flattenPointIndex(for: pin) else {
                host.showPlacementWarning("Move to a valid surface before placing the next Flatten point.")
                return
            }
            host.flattenAdjustingPointIndex = pinIndex
            host.showPlacementWarning("Corner \(pinIndex + 1) selected. Move to a valid surface and tap + to update it.")
            return
        }

        guard host.committedSegments.count < 3 else {
            arPlacementLog.notice("placeFlattenMarkAtReticle: ABORT four corners already placed")
            host.showPlacementWarning("All 4 corners are placed. Lock onto a corner to readjust it.")
            return
        }

        if let start = host.draftSegmentStart {
            if simd_distance(start, p) > 1e-5 {
                host.committedSegments.append(MeasurementSegment(start: start, end: p))
            }
            host.draftSegmentStart = host.committedSegments.count >= 3 ? nil : p
        } else if let lastEnd = host.committedSegments.last?.end {
            if simd_distance(lastEnd, p) > 1e-5 {
                host.committedSegments.append(MeasurementSegment(start: lastEnd, end: p))
            }
            host.draftSegmentStart = host.committedSegments.count >= 3 ? nil : p
        } else {
            host.draftSegmentStart = p
        }

        host.refreshMeasurementVisuals()
    }

    func rebuildCommittedFillGeometry() {
        guard let host, let container = host.committedFillContainer else { return }
        host.clearEntityChildren(container)

        arPlacementLog.notice("rebuildCommittedFillGeometry: isFlattenMode=true segCount=\(host.committedSegments.count)")

        guard !host.committedSegments.isEmpty else {
            container.isEnabled = false
            arPlacementLog.notice("rebuildCommittedFillGeometry: ABORT no segments")
            return
        }

        let segCount = host.committedSegments.count
        var points: [SIMD3<Float>] = []

        if segCount >= 1 {
            points.append(host.committedSegments[0].start)
            points.append(host.committedSegments[0].end)
        }
        if segCount >= 2 {
            points.append(host.committedSegments[1].end)
        }
        if segCount >= 3 {
            points.append(host.committedSegments[2].end)
        }

        arPlacementLog.notice("rebuildCommittedFillGeometry: points.count=\(points.count)")

        guard points.count >= 3 else {
            container.isEnabled = false
            arPlacementLog.notice("rebuildCommittedFillGeometry: ABORT insufficient points for fill")
            return
        }

        if let entity = makeFlattenFillEntity(points: points) {
            container.addChild(entity)
            container.isEnabled = true
            arPlacementLog.notice("rebuildCommittedFillGeometry: ✅ fill entity created and enabled")
        } else {
            container.isEnabled = false
            arPlacementLog.notice("rebuildCommittedFillGeometry: ❌ makeFlattenFillEntity returned nil")
        }
    }

    // MARK: - Flatten geometry helpers

    private func flattenPlacedPoints() -> [SIMD3<Float>] {
        guard let host else { return [] }
        if !host.committedSegments.isEmpty {
            return MeasurementSegment.endpointOnlyPinpointWorldPositions(for: host.committedSegments)
        }
        if let draftSegmentStart = host.draftSegmentStart {
            return [draftSegmentStart]
        }
        return []
    }

    private func flattenPointIndex(for pin: SIMD3<Float>) -> Int? {
        let points = flattenPlacedPoints()
        return points.enumerated().min(by: {
            simd_distance($0.element, pin) < simd_distance($1.element, pin)
        }).flatMap { index, point in
            simd_distance(point, pin) < 0.006 ? index : nil
        }
    }

    private func updateFlattenPoint(at index: Int, to point: SIMD3<Float>) {
        var points = flattenPlacedPoints()
        guard points.indices.contains(index) else { return }
        points[index] = point
        rebuildFlattenSegments(from: points)
    }

    private func rebuildFlattenSegments(from points: [SIMD3<Float>]) {
        guard let host else { return }
        host.committedSegments.removeAll()
        guard !points.isEmpty else {
            host.draftSegmentStart = nil
            return
        }

        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                if simd_distance(points[i], points[i + 1]) > 1e-5 {
                    host.committedSegments.append(MeasurementSegment(start: points[i], end: points[i + 1]))
                }
            }
        }

        host.draftSegmentStart = points.count >= 4 ? nil : points.last
    }

    // MARK: - Flatten previews (draft polyline + fill polygon)

    /// Draws a dynamic translucent polygon while aiming the 3rd or 4th corner in flatten mode.
    /// - 3rd corner aim (1 committed segment + draft): triangle [P1, P2, hover]
    /// - 4th corner aim (2 committed segments + draft): quad [P1, P2, P3, hover]
    private func updateFlattenFillPreview(hoverWorld: SIMD3<Float>) {
        guard let host, let container = host.flattenFillPreviewContainer else { return }

        if let adjustingIndex = host.flattenAdjustingPointIndex {
            var points = flattenPlacedPoints()
            guard points.indices.contains(adjustingIndex), points.count >= 3 else {
                if !container.children.isEmpty {
                    host.clearEntityChildren(container)
                }
                container.isEnabled = false
                return
            }
            points[adjustingIndex] = hoverWorld
            guard let entity = makeFlattenFillEntity(points: points) else {
                if !container.children.isEmpty {
                    host.clearEntityChildren(container)
                }
                container.isEnabled = false
                return
            }

            host.clearEntityChildren(container)
            container.addChild(entity)
            container.isEnabled = true
            return
        }

        guard host.draftSegmentStart != nil else {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        let segCount = host.committedSegments.count
        guard segCount == 1 || segCount == 2 else {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        var points: [SIMD3<Float>] = []
        points.append(host.committedSegments[0].start)
        points.append(host.committedSegments[0].end)
        if segCount == 2 {
            points.append(host.committedSegments[1].end)
        }
        points.append(hoverWorld)

        // Skip degenerate polygons (repeated / near-collinear last point).
        if simd_distance(points[points.count - 2], points[points.count - 1]) < 1e-4 {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        // Hide preview if P4 is inside triangle P1-P2-P3
        if points.count == 4 && isPointInsideTriangle(points[3], points[0], points[1], points[2]) {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        guard let entity = makeFlattenFillEntity(points: points) else {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        host.clearEntityChildren(container)
        container.addChild(entity)
        container.isEnabled = true
    }

    private func updateFlattenDraftPreview(reticleWorld: SIMD3<Float>) {
        guard let host, let lineContainer = host.previewLinesContainer else { return }

        host.draftPreviewLabelRoot?.isEnabled = false
        host.lastPreviewReadoutString = ""
        host.clearEntityChildren(lineContainer)

        if let adjustingIndex = host.flattenAdjustingPointIndex {
            let points = flattenPlacedPoints()
            guard points.indices.contains(adjustingIndex) else {
                lineContainer.isEnabled = false
                return
            }

            if adjustingIndex > 0 {
                host.addDottedLine(from: points[adjustingIndex - 1], to: reticleWorld, in: lineContainer)
            }
            if adjustingIndex + 1 < points.count {
                host.addDottedLine(from: points[adjustingIndex + 1], to: reticleWorld, in: lineContainer)
            }
            if points.count == 4, adjustingIndex == 3 {
                let edge = closestBaseTriangleEdge(to: reticleWorld, p1: points[0], p2: points[1], p3: points[2])
                host.clearEntityChildren(lineContainer)
                host.addDottedLine(from: edge.0, to: reticleWorld, in: lineContainer)
                host.addDottedLine(from: edge.1, to: reticleWorld, in: lineContainer)
            }
            lineContainer.isEnabled = !lineContainer.children.isEmpty
            return
        }

        guard host.draftSegmentStart != nil else {
            lineContainer.isEnabled = false
            return
        }

        switch host.committedSegments.count {
        case 0:
            guard let start = host.draftSegmentStart else {
                lineContainer.isEnabled = false
                return
            }
            host.addDottedLine(from: start, to: reticleWorld, in: lineContainer)

        case 1:
            host.addDottedLine(from: host.committedSegments[0].end, to: reticleWorld, in: lineContainer)

        case 2:
            let p1 = host.committedSegments[0].start
            let p2 = host.committedSegments[0].end
            let p3 = host.committedSegments[1].end
            let edge = closestBaseTriangleEdge(to: reticleWorld, p1: p1, p2: p2, p3: p3)
            host.addDottedLine(from: edge.0, to: reticleWorld, in: lineContainer)
            host.addDottedLine(from: edge.1, to: reticleWorld, in: lineContainer)

        default:
            lineContainer.isEnabled = false
            return
        }

        lineContainer.isEnabled = !lineContainer.children.isEmpty
    }

    private func closestBaseTriangleEdge(
        to point: SIMD3<Float>,
        p1: SIMD3<Float>,
        p2: SIMD3<Float>,
        p3: SIMD3<Float>
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let distToEdge12 = distanceFromPointToSegment3D(point, p1, p2)
        let distToEdge23 = distanceFromPointToSegment3D(point, p2, p3)
        let distToEdge31 = distanceFromPointToSegment3D(point, p3, p1)

        if distToEdge12 <= distToEdge23 && distToEdge12 <= distToEdge31 {
            return (p1, p2)
        }
        if distToEdge23 <= distToEdge31 {
            return (p2, p3)
        }
        return (p3, p1)
    }

    /// Builds a double-sided triangle-fan mesh over `points` (>= 3) with a translucent teal material.
    private func makeFlattenFillEntity(points: [SIMD3<Float>]) -> ModelEntity? {
        guard points.count >= 3 else { return nil }

        var descriptor = MeshDescriptor(name: "FlattenFillPreview")

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Front-facing triangles
        for p in points { positions.append(p) }

        if points.count == 3 {
            // Simple triangle
            indices.append(contentsOf: [0, 1, 2])
        } else if points.count == 4 {
            // Keep the base triangle (P1-P2-P3) and add one extra triangle from P4
            // to whichever edge of the base triangle is closest.
            indices.append(contentsOf: [0, 1, 2])

            // Find which edge of triangle P1-P2-P3 is closest to P4
            let p1 = points[0], p2 = points[1], p3 = points[2], p4 = points[3]

            let distToEdge12 = distanceFromPointToSegment3D(p4, p1, p2)
            let distToEdge23 = distanceFromPointToSegment3D(p4, p2, p3)
            let distToEdge31 = distanceFromPointToSegment3D(p4, p3, p1)

            if distToEdge12 <= distToEdge23 && distToEdge12 <= distToEdge31 {
                // Closest to P1-P2: connect P4 to that edge
                // Triangles: [P1,P2,P4]
                indices.append(contentsOf: [0, 1, 3])
            } else if distToEdge23 <= distToEdge31 {
                // Closest to P2-P3: connect P4 to that edge
                // Triangles: [P2,P3,P4]
                indices.append(contentsOf: [1, 2, 3])
            } else {
                // Closest to P3-P1: connect P4 to that edge
                // Triangles: [P3,P1,P4]
                indices.append(contentsOf: [2, 0, 3])
            }
        }

        // Back-facing triangles (duplicated verts, reversed winding for double-sided visibility)
        let backOffset = UInt32(positions.count)
        for p in points { positions.append(p) }

        if points.count == 3 {
            indices.append(contentsOf: [backOffset + 0, backOffset + 2, backOffset + 1])
        } else if points.count == 4 {
            // Back face for base triangle (reverse winding)
            indices.append(contentsOf: [backOffset + 0, backOffset + 2, backOffset + 1])

            let p1 = points[0], p2 = points[1], p3 = points[2], p4 = points[3]

            let distToEdge12 = distanceFromPointToSegment3D(p4, p1, p2)
            let distToEdge23 = distanceFromPointToSegment3D(p4, p2, p3)
            let distToEdge31 = distanceFromPointToSegment3D(p4, p3, p1)

            if distToEdge12 <= distToEdge23 && distToEdge12 <= distToEdge31 {
                indices.append(contentsOf: [backOffset + 0, backOffset + 3, backOffset + 1])

            } else if distToEdge23 <= distToEdge31 {
                indices.append(contentsOf: [backOffset + 1, backOffset + 3, backOffset + 2])

            } else {
                indices.append(contentsOf: [backOffset + 2, backOffset + 3, backOffset + 0])

            }
        }

        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            var material = UnlitMaterial()
            material.color = .init(tint: .systemTeal)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.3))
            return ModelEntity(mesh: mesh, materials: [material])
        } catch {
            arPlacementLog.warning("makeFlattenFillEntity: mesh generation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // Calculate 3D distance from point to line segment
    private func distanceFromPointToSegment3D(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let ap = p - a
        let ab2 = simd_length_squared(ab)

        if ab2 < 1e-8 {
            return simd_distance(p, a)
        }

        var t = simd_dot(ap, ab) / ab2
        t = min(max(t, 0), 1)  // Clamp to [0, 1] for segment
        let closest = a + t * ab
        return simd_distance(p, closest)
    }

    // Test if point is inside triangle using barycentric coordinates (projected to XZ plane)
    private func isPointInsideTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
        // 2D cross product helper (projects to horizontal XZ plane)
        func sign(_ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) -> Float {
            return (p1.x - p3.x) * (p2.z - p3.z) - (p2.x - p3.x) * (p1.z - p3.z)
        }

        let d1 = sign(p, a, b)
        let d2 = sign(p, b, c)
        let d3 = sign(p, c, a)

        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)

        // Point is inside if all signs are the same (all positive or all negative)
        return !(hasNeg && hasPos)
    }
}
