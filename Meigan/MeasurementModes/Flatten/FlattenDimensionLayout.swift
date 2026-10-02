//
//  FlattenDimensionLayout.swift
//  Meigan
//
//  Decides whether each measured chord is drawn on the object or, engineering-drawing style,
//  as a dimension line offset past it with extension lines back to the measured points.
//  Pure geometry so the inspect overlay and the exported image lay lines out identically.
//

import CoreGraphics

/// Where one axis's dimension line is drawn, in view space.
enum FlattenDimensionPlacement: Equatable, Sendable {
    /// Drawn on the measured chord itself.
    case interior(FlattenMeasureSegment)
    /// Drawn parallel to the chord past the object. Each extension line runs from a measured
    /// point to just beyond the matching end of `dimensionLine`.
    case exterior(
        dimensionLine: FlattenMeasureSegment,
        extensionA: FlattenMeasureSegment,
        extensionB: FlattenMeasureSegment
    )

    var isExterior: Bool {
        if case .exterior = self { return true }
        return false
    }
}

enum FlattenDimensionLayout {

    // MARK: - Types

    enum Axis: Sendable {
        case width
        case height
    }

    /// Distances in view units: points on screen, or pixels via ``scaled(by:)`` for export.
    struct Metrics: Equatable, Sendable {
        /// Below this, the line would sit on top of the contour stroke.
        var minimumClearance: CGFloat = 6
        /// Tilted lines near a stair-stepped edge are hard to follow, so they need more room.
        var tiltedMinimumClearance: CGFloat = 12
        /// Shorter than this, two arrowheads plus a dash gap don't fit.
        var minimumLength: CGFloat = 40
        var arrowheadLength: CGFloat = 10
        var clearanceSampleSpacing: CGFloat = 2
        /// Gap between the object's oriented bounds and an exterior dimension line.
        var exteriorOffset: CGFloat = 14
        /// How far extension lines run past the dimension line.
        var extensionOvershoot: CGFloat = 4
        /// Exterior lines must stay this far inside the displayed image.
        var boundsMargin: CGFloat = 12

        static let screen = Metrics()

        func scaled(by factor: CGFloat) -> Metrics {
            Metrics(
                minimumClearance: minimumClearance * factor,
                tiltedMinimumClearance: tiltedMinimumClearance * factor,
                minimumLength: minimumLength * factor,
                arrowheadLength: arrowheadLength * factor,
                clearanceSampleSpacing: clearanceSampleSpacing * factor,
                exteriorOffset: exteriorOffset * factor,
                extensionOvershoot: extensionOvershoot * factor,
                boundsMargin: boundsMargin * factor
            )
        }
    }

    /// Things an exterior line should avoid crossing.
    struct Obstacles: Sendable {
        /// Other findings, in image space.
        var findings: [FlattenShapeFinding] = []
        /// View-space areas such as the legend card.
        var rects: [CGRect] = []
    }

    /// Chords tilted this far from image-horizontal use ``Metrics/tiltedMinimumClearance``.
    static let tiltedRangeDegrees: ClosedRange<CGFloat> = 20...70

    // MARK: - Layout

    /// Picks interior or exterior placement for one axis of `finding`.
    ///
    /// - Parameters:
    ///   - imageToView: Maps warped image pixels to view space. Must be a uniform scale plus
    ///     translation so angles are preserved.
    ///   - viewBounds: The displayed image rect in view space. Exterior lines never leave it.
    static func layout(
        for axis: Axis,
        of finding: FlattenShapeFinding,
        imageToView: CGAffineTransform,
        viewBounds: CGRect,
        obstacles: Obstacles = Obstacles(),
        metrics: Metrics = .screen
    ) -> FlattenDimensionPlacement {
        let imageChord = axis == .width ? finding.widthSegment : finding.heightSegment
        let chord = FlattenMeasureSegment(
            start: imageChord.start.applying(imageToView),
            end: imageChord.end.applying(imageToView)
        )
        let length = chord.length
        guard length > 0 else { return .interior(chord) }

        let direction = CGVector(dx: (chord.end.x - chord.start.x) / length, dy: (chord.end.y - chord.start.y) / length)
        let contour = finding.contourImage.map { $0.applying(imageToView) }
        guard needsExteriorPlacement(chord: chord, direction: direction, contour: contour, metrics: metrics) else {
            return .interior(chord)
        }

        // The width and height axes are the minimum-area rectangle's axes, so projecting the
        // contour onto the chord's normal recovers that rectangle's two sides.
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let projections = contour.map { dot($0, normal) }
        guard let minProjection = projections.min(), let maxProjection = projections.max() else {
            return .interior(chord)
        }

        let fittingBounds = viewBounds.insetBy(dx: metrics.boundsMargin, dy: metrics.boundsMargin)
        let sides: [(offset: CGFloat, sign: CGFloat)] = [
            (maxProjection + metrics.exteriorOffset, 1),
            (minProjection - metrics.exteriorOffset, -1)
        ]
        let best = sides
            .compactMap { side in
                exteriorCandidate(
                    for: chord,
                    normal: normal,
                    lineProjection: side.offset,
                    outwardSign: side.sign,
                    fittingBounds: fittingBounds,
                    obstacles: obstacles,
                    imageToView: imageToView,
                    metrics: metrics
                )
            }
            .min { lhs, rhs in
                lhs.obstacleHits != rhs.obstacleHits
                    ? lhs.obstacleHits < rhs.obstacleHits
                    : lhs.room > rhs.room
            }
        return best?.placement ?? .interior(chord)
    }

    /// Rotation of `finding`'s width axis from image-horizontal, in degrees, `0...45`.
    static func rotationDegrees(of finding: FlattenShapeFinding) -> CGFloat {
        abs(finding.orientationRadians) * 180 / .pi
    }

    /// The legend explains diagonal or pushed-out lines with a rotation row.
    static func shouldShowRotation(for finding: FlattenShapeFinding, placements: [FlattenDimensionPlacement]) -> Bool {
        placements.contains(where: \.isExterior) || rotationDegrees(of: finding) > tiltedRangeDegrees.lowerBound
    }

    // MARK: - Legibility

    private static func needsExteriorPlacement(
        chord: FlattenMeasureSegment,
        direction: CGVector,
        contour: [CGPoint],
        metrics: Metrics
    ) -> Bool {
        if chord.length < metrics.minimumLength { return true }

        let tiltDegrees = atan2(abs(direction.dy), abs(direction.dx)) * 180 / .pi
        let requiredClearance = tiltedRangeDegrees.contains(tiltDegrees)
            ? metrics.tiltedMinimumClearance
            : metrics.minimumClearance
        return !hasClearance(
            chord,
            direction: direction,
            from: contour,
            atLeast: requiredClearance,
            metrics: metrics
        )
    }

    /// Samples along the chord, skipping each end by the arrowhead plus `required`. The chord
    /// ends on the contour, so a sample closer than that to an end could never clear a contour
    /// that crosses it squarely; a shallow crossing still fails, which is the intent.
    private static func hasClearance(
        _ chord: FlattenMeasureSegment,
        direction: CGVector,
        from contour: [CGPoint],
        atLeast required: CGFloat,
        metrics: Metrics
    ) -> Bool {
        guard contour.count >= 2 else { return true }
        let length = chord.length
        let skip = metrics.arrowheadLength + required

        var distances: [CGFloat] = Array(stride(from: skip, through: length - skip, by: metrics.clearanceSampleSpacing))
        if distances.isEmpty {
            distances = [length / 2]
        }
        let samples = distances.map { offset(chord.start, along: direction, by: $0) }

        let reach = boundingRect(of: samples).insetBy(dx: -required, dy: -required)
        let nearbyEdges = closedEdges(of: contour).filter { boundingRect(of: [$0.0, $0.1]).intersects(reach) }
        let requiredSquared = required * required
        for sample in samples {
            for edge in nearbyEdges where squaredDistance(from: sample, toSegment: edge) < requiredSquared {
                return false
            }
        }
        return true
    }

    // MARK: - Exterior Candidates

    private struct ExteriorCandidate {
        let placement: FlattenDimensionPlacement
        /// Crossed contours of other findings plus overlapped obstacle rects.
        let obstacleHits: Int
        /// Shortest distance from the line's ends to the edge of the fitting bounds.
        let room: CGFloat
    }

    /// Nil when the line or its extensions would leave `fittingBounds`.
    private static func exteriorCandidate(
        for chord: FlattenMeasureSegment,
        normal: CGVector,
        lineProjection: CGFloat,
        outwardSign: CGFloat,
        fittingBounds: CGRect,
        obstacles: Obstacles,
        imageToView: CGAffineTransform,
        metrics: Metrics
    ) -> ExteriorCandidate? {
        let shift = lineProjection - dot(chord.start, normal)
        let dimensionLine = FlattenMeasureSegment(
            start: offset(chord.start, along: normal, by: shift),
            end: offset(chord.end, along: normal, by: shift)
        )
        let overshoot = outwardSign * metrics.extensionOvershoot
        let extensionA = FlattenMeasureSegment(
            start: chord.start,
            end: offset(dimensionLine.start, along: normal, by: overshoot)
        )
        let extensionB = FlattenMeasureSegment(
            start: chord.end,
            end: offset(dimensionLine.end, along: normal, by: overshoot)
        )

        // The bounds are convex and the chord ends lie on the object, so checking the outer
        // ends covers every drawn line.
        let outerPoints = [dimensionLine.start, dimensionLine.end, extensionA.end, extensionB.end]
        guard fittingBounds.width > 0, fittingBounds.height > 0,
              outerPoints.allSatisfy(fittingBounds.contains)
        else { return nil }

        let lines = [dimensionLine, extensionA, extensionB]
        let room = outerPoints.map { distanceToEdges(of: fittingBounds, from: $0) }.min() ?? 0
        return ExteriorCandidate(
            placement: .exterior(dimensionLine: dimensionLine, extensionA: extensionA, extensionB: extensionB),
            obstacleHits: obstacleHits(for: lines, obstacles: obstacles, imageToView: imageToView),
            room: room
        )
    }

    private static func obstacleHits(
        for lines: [FlattenMeasureSegment],
        obstacles: Obstacles,
        imageToView: CGAffineTransform
    ) -> Int {
        let linesBounds = boundingRect(of: lines.flatMap { [$0.start, $0.end] })

        let crossedContours = obstacles.findings.filter { finding in
            guard finding.boundingRectImage.applying(imageToView).intersects(linesBounds) else { return false }
            let contour = finding.contourImage.map { $0.applying(imageToView) }
            return closedEdges(of: contour).contains { edge in
                lines.contains { segmentsIntersect($0.start, $0.end, edge.0, edge.1) }
            }
        }.count

        let overlappedRects = obstacles.rects.filter { rect in
            lines.contains { segment($0, intersects: rect) }
        }.count

        return crossedContours + overlappedRects
    }

    // MARK: - Geometry Helpers

    @inline(__always)
    private static func dot(_ point: CGPoint, _ axis: CGVector) -> CGFloat {
        point.x * axis.dx + point.y * axis.dy
    }

    @inline(__always)
    private static func offset(_ point: CGPoint, along axis: CGVector, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + axis.dx * distance, y: point.y + axis.dy * distance)
    }

    private static func closedEdges(of polygon: [CGPoint]) -> [(CGPoint, CGPoint)] {
        guard polygon.count >= 2 else { return [] }
        return polygon.indices.map { (polygon[$0], polygon[($0 + 1) % polygon.count]) }
    }

    private static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func squaredDistance(from point: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let abX = b.x - a.x
        let abY = b.y - a.y
        let lengthSquared = abX * abX + abY * abY
        let t = lengthSquared > 0
            ? min(max(((point.x - a.x) * abX + (point.y - a.y) * abY) / lengthSquared, 0), 1)
            : 0
        let dx = point.x - (a.x + t * abX)
        let dy = point.y - (a.y + t * abY)
        return dx * dx + dy * dy
    }

    private static func distanceToEdges(of rect: CGRect, from point: CGPoint) -> CGFloat {
        min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }

    /// Z component of `(a - origin) × (b - origin)`.
    @inline(__always)
    private static func cross(_ origin: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
    }

    /// Includes touching and collinear overlap.
    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        let d1 = cross(q1, q2, p1)
        let d2 = cross(q1, q2, p2)
        let d3 = cross(p1, p2, q1)
        let d4 = cross(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }

        func isOnSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool {
            point.x >= min(a.x, b.x) && point.x <= max(a.x, b.x)
                && point.y >= min(a.y, b.y) && point.y <= max(a.y, b.y)
        }
        return (d1 == 0 && isOnSegment(p1, q1, q2))
            || (d2 == 0 && isOnSegment(p2, q1, q2))
            || (d3 == 0 && isOnSegment(q1, p1, p2))
            || (d4 == 0 && isOnSegment(q2, p1, p2))
    }

    private static func segment(_ segment: FlattenMeasureSegment, intersects rect: CGRect) -> Bool {
        if rect.contains(segment.start) || rect.contains(segment.end) { return true }
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        return closedEdges(of: corners).contains {
            segmentsIntersect(segment.start, segment.end, $0.0, $0.1)
        }
    }
}
