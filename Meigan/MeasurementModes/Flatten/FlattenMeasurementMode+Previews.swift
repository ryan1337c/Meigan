//
//  FlattenMeasurementMode+Previews.swift
//  Meigan
//
//  Live draft polyline and translucent fill polygon shown while aiming corners, plus the
//  RealityKit mesh used for both the preview and the committed fill.
//

import OSLog
import RealityKit
import simd
import UIKit

private let arPlacementLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

extension FlattenMeasurementMode {
    // MARK: - Flatten previews (draft polyline + fill polygon)

    /// Draws a dynamic translucent polygon while aiming the 3rd or 4th corner in flatten mode.
    /// - 3rd corner aim (1 committed segment + draft): triangle [P1, P2, hover]
    /// - 4th corner aim (2 committed segments + draft): quad [P1, P2, P3, hover]
    func updateFlattenFillPreview(hoverWorld: SIMD3<Float>) {
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

    func updateFlattenDraftPreview(reticleWorld: SIMD3<Float>) {
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
    func makeFlattenFillEntity(points: [SIMD3<Float>]) -> ModelEntity? {
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
            // iOS 17+ RealityKit can ignore `material.blending = .transparent(opacity:)`
            // when the tint color is fully opaque; encode alpha directly on the tint so
            // the fill is always translucent regardless of OS version.
            let translucentTint = UIColor.systemTeal.withAlphaComponent(0.3)
            var material = UnlitMaterial()
            material.color = .init(tint: translucentTint)
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
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
