//
//  FlattenRectifiedEdgeAnalysis+Dimensions.swift
//  Meigan
//
//  Oriented width and height of a contour polygon: convex hull (Andrew's monotone chain),
//  minimum-area bounding rectangle (rotating calipers) for the object's axes, then the
//  longest interior chord along each axis.
//

import CoreGraphics

/// Oriented chords measured on one contour, in warped pixel space.
struct FlattenOrientedDimensions: Equatable, Sendable {
    /// Longest interior chord along the axis closer to image-horizontal.
    let widthSegment: FlattenMeasureSegment
    /// Longest interior chord along the perpendicular axis.
    let heightSegment: FlattenMeasureSegment
    /// Rotation of the width axis from image-horizontal, in `-π/4...π/4`.
    let orientationRadians: CGFloat
}

extension FlattenRectifiedEdgeAnalysis {

    // MARK: - Constants

    /// Distance between scanlines when searching for the longest interior chord.
    private static let chordScanlineSpacing: CGFloat = 0.5

    /// Chords within this many pixels of the longest count as equally long, so the reported
    /// length can be at most this much under the true maximum.
    private static let chordLengthTieTolerance: CGFloat = 0.25

    /// A minimum-area rectangle whose side ratio is within this of 1 has no stable
    /// orientation (e.g. a circle), so its angle snaps to 0.
    private static let nearSquareAspectTolerance: CGFloat = 0.02

    // MARK: - Dimensions

    /// Oriented width and height chords of a closed `contour`. The first point may be repeated
    /// at the end. Returns nil when the contour has no area.
    static func orientedDimensions(of contour: [CGPoint]) -> FlattenOrientedDimensions? {
        let hull = convexHull(of: contour)
        guard let rect = minimumAreaRectangle(ofHull: hull) else { return nil }

        let aspect = min(rect.extentU, rect.extentV) / max(rect.extentU, rect.extentV)
        let widthAxis: CGVector
        if aspect >= 1 - nearSquareAspectTolerance {
            widthAxis = CGVector(dx: 1, dy: 0)
        } else {
            let u = rect.axisU
            let v = CGVector(dx: -u.dy, dy: u.dx)
            let closerToHorizontal = abs(u.dx) >= abs(v.dx) ? u : v
            widthAxis = closerToHorizontal.dx < 0
                ? CGVector(dx: -closerToHorizontal.dx, dy: -closerToHorizontal.dy)
                : closerToHorizontal
        }
        // Points down the image (+y) because `widthAxis.dx` is non-negative.
        let heightAxis = CGVector(dx: -widthAxis.dy, dy: widthAxis.dx)

        guard let widthSegment = longestInteriorChord(of: contour, along: widthAxis),
              let heightSegment = longestInteriorChord(of: contour, along: heightAxis)
        else { return nil }

        return FlattenOrientedDimensions(
            widthSegment: widthSegment,
            heightSegment: heightSegment,
            orientationRadians: atan2(widthAxis.dy, widthAxis.dx)
        )
    }

    // MARK: - Convex Hull

    /// Andrew's monotone chain. Returns hull vertices with positive cross-product winding and
    /// no collinear or duplicate points.
    static func convexHull(of points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }

        func buildChain<S: Sequence>(_ sequence: S) -> [CGPoint] where S.Element == CGPoint {
            var chain: [CGPoint] = []
            for point in sequence {
                while chain.count >= 2,
                      cross(chain[chain.count - 2], chain[chain.count - 1], point) <= 0 {
                    chain.removeLast()
                }
                chain.append(point)
            }
            return chain
        }

        let lower = buildChain(sorted)
        let upper = buildChain(sorted.reversed())
        // Each chain's last point is the other chain's first.
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    // MARK: - Minimum-Area Rectangle

    private struct OrientedRectangle {
        /// Unit direction of one side; the other side runs along its perpendicular.
        let axisU: CGVector
        let extentU: CGFloat
        let extentV: CGFloat
    }

    /// Rotating calipers over a convex hull from ``convexHull(of:)``. One side of the
    /// minimum-area rectangle is always collinear with a hull edge, so each edge is tried while
    /// three calipers track the extreme vertices along, against, and away from it.
    private static func minimumAreaRectangle(ofHull hull: [CGPoint]) -> OrientedRectangle? {
        let count = hull.count
        guard count >= 3 else { return nil }

        @inline(__always)
        func dot(_ point: CGPoint, _ axis: CGVector) -> CGFloat {
            point.x * axis.dx + point.y * axis.dy
        }

        func extremeIndex(along axis: CGVector, isMaximum: Bool) -> Int {
            var best = 0
            for i in 1..<count {
                let isBetter = isMaximum
                    ? dot(hull[i], axis) > dot(hull[best], axis)
                    : dot(hull[i], axis) < dot(hull[best], axis)
                if isBetter { best = i }
            }
            return best
        }

        var forward = 0
        var far = 0
        var backward = 0
        var best: OrientedRectangle?
        var bestArea = CGFloat.infinity

        for i in 0..<count {
            let start = hull[i]
            let end = hull[(i + 1) % count]
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else { continue }
            let u = CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
            // Points into the hull because of its winding.
            let v = CGVector(dx: -u.dy, dy: u.dx)

            if best == nil {
                forward = extremeIndex(along: u, isMaximum: true)
                far = extremeIndex(along: v, isMaximum: true)
                backward = extremeIndex(along: u, isMaximum: false)
            } else {
                // The extremes only move forward around the hull as the edge direction rotates.
                while dot(hull[(forward + 1) % count], u) > dot(hull[forward], u) {
                    forward = (forward + 1) % count
                }
                while dot(hull[(far + 1) % count], v) > dot(hull[far], v) {
                    far = (far + 1) % count
                }
                while dot(hull[(backward + 1) % count], u) < dot(hull[backward], u) {
                    backward = (backward + 1) % count
                }
            }

            let extentU = dot(hull[forward], u) - dot(hull[backward], u)
            let extentV = dot(hull[far], v) - dot(start, v)
            let area = extentU * extentV
            if area < bestArea {
                bestArea = area
                best = OrientedRectangle(axisU: u, extentU: extentU, extentV: extentV)
            }
        }

        guard let best, best.extentU > 0, best.extentV > 0 else { return nil }
        return best
    }

    // MARK: - Interior Chord

    /// Longest segment parallel to `axis` that lies inside `polygon`, found by sweeping
    /// scanlines across the polygon in a frame where `axis` is horizontal. Among near-ties,
    /// returns the middle one.
    private static func longestInteriorChord(
        of polygon: [CGPoint],
        along axis: CGVector
    ) -> FlattenMeasureSegment? {
        guard polygon.count >= 3 else { return nil }
        let normal = CGVector(dx: -axis.dy, dy: axis.dx)
        let local = polygon.map {
            CGPoint(x: $0.x * axis.dx + $0.y * axis.dy, y: $0.x * normal.dx + $0.y * normal.dy)
        }

        guard let minY = local.map(\.y).min(), let maxY = local.map(\.y).max() else { return nil }
        let spacing = chordScanlineSpacing
        // Offsetting by half a spacing keeps scanlines off the extreme vertices.
        let firstScanlineY = minY + spacing / 2
        let scanlineCount = Int(((maxY - firstScanlineY) / spacing).rounded(.down)) + 1
        guard scanlineCount > 0 else { return nil }

        // Bucketing each edge's crossings by scanline keeps the sweep linear in the number of
        // crossings rather than scanlines × edges.
        var crossings = [[CGFloat]](repeating: [], count: scanlineCount)
        for i in local.indices {
            let a = local[i]
            let b = local[(i + 1) % local.count]
            guard a.y != b.y else { continue }
            let low = min(a.y, b.y)
            let high = max(a.y, b.y)
            // Half-open `[low, high)` so a scanline through a shared vertex counts it once.
            let firstIndex = max(0, Int(((low - firstScanlineY) / spacing).rounded(.up)))
            let endIndex = min(scanlineCount, Int(((high - firstScanlineY) / spacing).rounded(.up)))
            guard firstIndex < endIndex else { continue }
            let slope = (b.x - a.x) / (b.y - a.y)
            for index in firstIndex..<endIndex {
                let y = firstScanlineY + CGFloat(index) * spacing
                crossings[index].append(a.x + (y - a.y) * slope)
            }
        }

        var intervals: [(start: CGPoint, end: CGPoint)] = []
        var bestLength: CGFloat = 0
        for (index, var xs) in crossings.enumerated() where xs.count >= 2 {
            xs.sort()
            let y = firstScanlineY + CGFloat(index) * spacing
            // Even–odd pairing gives the inside intervals.
            for pair in stride(from: 0, to: xs.count - 1, by: 2) {
                intervals.append((CGPoint(x: xs[pair], y: y), CGPoint(x: xs[pair + 1], y: y)))
                bestLength = max(bestLength, xs[pair + 1] - xs[pair])
            }
        }

        // Straight-sided shapes have many equally long chords. Taking the middle one keeps the
        // drawn line away from the contour instead of hugging the first scanline.
        let nearLongest = intervals.filter { $0.end.x - $0.start.x >= bestLength - chordLengthTieTolerance }
        guard bestLength > 0, !nearLongest.isEmpty else { return nil }
        let bestChord = nearLongest[nearLongest.count / 2]
        func toImage(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x * axis.dx + point.y * normal.dx,
                y: point.x * axis.dy + point.y * normal.dy
            )
        }
        return FlattenMeasureSegment(start: toImage(bestChord.start), end: toImage(bestChord.end))
    }

    // MARK: - Helpers

    /// Z component of `(a - origin) × (b - origin)`.
    @inline(__always)
    private static func cross(_ origin: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
    }
}
