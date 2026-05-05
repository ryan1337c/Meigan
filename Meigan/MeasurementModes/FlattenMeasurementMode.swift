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
                return
            }
            updateFlattenPoint(at: adjustingIndex, to: p)
            host.flattenAdjustingPointIndex = nil
            host.refreshMeasurementVisuals()
            return
        }

        if let pin = host.latestPinAutolockWorld {
            guard let pinIndex = flattenPointIndex(for: pin) else {
                host.showPlacementWarning("Move to a valid surface before placing the next Flatten point.", kind: .alert)
                return
            }
            host.flattenAdjustingPointIndex = pinIndex
            host.refreshMeasurementVisuals()
            host.showPlacementWarning(
                "Corner \(pinIndex + 1) selected — move to the new position, then tap +",
                kind: .instruction
            )
            return
        }

        guard host.committedSegments.count < 3 else {
            arPlacementLog.notice("placeFlattenMarkAtReticle: ABORT four corners already placed")
            host.showPlacementWarning("All 4 corners are placed. Lock onto a corner to readjust it.", kind: .instruction)
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

    func startScan() {
        guard let host, let arView = host.arView else {
            cancelScan(message: "Scan cancelled. AR view is not ready.")
            return
        }
        guard !host.isFlattenScanActive else { return }

        let points = Array(flattenPlacedPoints().prefix(4))
        guard points.count == 4, host.flattenAdjustingPointIndex == nil else {
            cancelScan(message: "Scan cancelled. Complete the 4 corners first.")
            return
        }

        guard allPointsVisible(points, in: arView) else {
            host.showPlacementWarning("Aim the camera so all 4 corners are visible, then tap Scan.", kind: .instruction)
            return
        }


        arView.snapshot(saveToHDR: false) { [weak self, weak host, weak arView] image in
            DispatchQueue.main.async {
                guard let self, let host, let arView, let image else { return }
                let currentPoints = Array(self.flattenPlacedPoints().prefix(4))
                guard Self.pointsMatch(points, currentPoints),
                      self.allPointsVisible(currentPoints, in: arView)
                else {
                    host.showPlacementWarning("Aim the camera so all 4 corners are visible, then tap Scan.", kind: .instruction)
                    return
                }

                let previewImage = Self.croppedScanImage(from: image, around: currentPoints, in: arView)
                self.beginScan(with: previewImage, points: currentPoints)
            }
        }
    }

    private func beginScan(with previewImage: UIImage, points: [SIMD3<Float>]) {
        guard let host else {
            cancelScan(message: "Scan cancelled. AR view is not ready.")
            return
        }

        host.flattenScanPreviewImage = previewImage
        host.flattenScanSigmas = []
        host.isFlattenScanActive = true

        DispatchQueue.global(qos: .userInitiated).async {
            let sigmas = Self.singularValues(for: points)
            let minimumAnimationDuration: TimeInterval = 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumAnimationDuration) {
                host.flattenScanSigmas = sigmas
                host.isFlattenScanActive = false
                host.flattenScanPreviewImage = nil
                host.showPlacementWarning(Self.scanCompleteMessage(sigmas: sigmas), kind: .instruction)
            }
        }
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

    private func cancelScan(message: String) {
        guard let host else { return }
        DispatchQueue.main.async {
            host.isFlattenScanActive = false
            host.flattenScanPreviewImage = nil
            host.flattenScanSigmas = []
            host.showPlacementWarning(message, kind: .alert)
        }
    }

    private static func scanCompleteMessage(sigmas: [Float]) -> String {
        let values = sigmas.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        return "Scan complete. sigmas: \(values)"
    }

    private static func pointsMatch(_ lhs: [SIMD3<Float>], _ rhs: [SIMD3<Float>]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { simd_distance($0, $1) < 0.0005 }
    }

    private func allPointsVisible(_ points: [SIMD3<Float>], in arView: ARView) -> Bool {
        guard points.count == 4 else { return false }
        let bounds = arView.bounds.insetBy(dx: 12, dy: 12)
        return points.allSatisfy { point in
            guard let projected = arView.project(point) else { return false }
            return bounds.contains(projected)
        }
    }

    /// True when the quad is complete and every corner projects inside the AR view (same gate as `startScan`).
    func scanCornersVisible(in arView: ARView) -> Bool {
        let points = Array(flattenPlacedPoints().prefix(4))
        guard points.count == 4 else { return false }
        return allPointsVisible(points, in: arView)
    }

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

    private static func croppedScanImage(
        from image: UIImage,
        around points: [SIMD3<Float>],
        in arView: ARView
    ) -> UIImage {
        guard let cgImage = image.cgImage, !points.isEmpty else { return image }

        let projected = points.compactMap { arView.project($0) }
        guard projected.count == points.count else { return image }

        let xs = projected.map(\.x)
        let ys = projected.map(\.y)
        let padding: CGFloat = 28
        let viewBounds = arView.bounds
        let minX = max((xs.min() ?? 0) - padding, viewBounds.minX)
        let maxX = min((xs.max() ?? viewBounds.maxX) + padding, viewBounds.maxX)
        let minY = max((ys.min() ?? 0) - padding, viewBounds.minY)
        let maxY = min((ys.max() ?? viewBounds.maxY) + padding, viewBounds.maxY)

        guard maxX > minX, maxY > minY, viewBounds.width > 0, viewBounds.height > 0 else {
            return image
        }

        let scaleX = CGFloat(cgImage.width) / viewBounds.width
        let scaleY = CGFloat(cgImage.height) / viewBounds.height
        let cropRect = CGRect(
            x: minX * scaleX,
            y: minY * scaleY,
            width: (maxX - minX) * scaleX,
            height: (maxY - minY) * scaleY
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))

        guard !cropRect.isNull,
              cropRect.width > 1,
              cropRect.height > 1,
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return image
        }

        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func singularValues(for points: [SIMD3<Float>]) -> [Float] {
        guard !points.isEmpty else { return [0, 0, 0] }

        let count = Float(points.count)
        let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / count
        var covariance = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)

        for point in points {
            let centered = point - centroid
            let v = [Double(centered.x), Double(centered.y), Double(centered.z)]
            for row in 0..<3 {
                for col in 0..<3 {
                    covariance[row][col] += v[row] * v[col]
                }
            }
        }

        return jacobiEigenvaluesSymmetric3(covariance)
            .map { Float(sqrt(max($0, 0))) }
            .sorted(by: >)
    }

    private static func jacobiEigenvaluesSymmetric3(_ matrix: [[Double]]) -> [Double] {
        var a = matrix
        let iterations = 32

        for _ in 0..<iterations {
            var p = 0
            var q = 1
            var largest = abs(a[0][1])

            let pairs = [(0, 2), (1, 2)]
            for pair in pairs {
                let value = abs(a[pair.0][pair.1])
                if value > largest {
                    largest = value
                    p = pair.0
                    q = pair.1
                }
            }

            if largest < 1e-12 { break }

            let app = a[p][p]
            let aqq = a[q][q]
            let apq = a[p][q]
            let tau = (aqq - app) / (2 * apq)
            let sign = tau >= 0 ? 1.0 : -1.0
            let t = sign / (abs(tau) + sqrt(1 + tau * tau))
            let c = 1 / sqrt(1 + t * t)
            let s = t * c

            for k in 0..<3 where k != p && k != q {
                let akp = a[k][p]
                let akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[p][k] = a[k][p]
                a[k][q] = s * akp + c * akq
                a[q][k] = a[k][q]
            }

            a[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq
            a[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq
            a[p][q] = 0
            a[q][p] = 0
        }

        return [a[0][0], a[1][1], a[2][2]]
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
