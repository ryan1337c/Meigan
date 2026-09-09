import simd

/// One finished measurement edge in world space.
///
/// Store segments in an **append-only** array so index order is chronological (oldest first, newest last).
/// This matches common CAD / surveying “polyline with explicit edges” models and avoids duplicating shared vertices.
struct MeasurementSegment: Sendable, Equatable {
    var start: SIMD3<Float>
    var end: SIMD3<Float>

    var midpoint: SIMD3<Float> { (start + end) * 0.5 }

    var lengthMeters: Float { simd_distance(start, end) }

    /// World positions used for reticle autolock: each endpoint and each segment midpoint (3 per segment).
    static func allPinpointWorldPositions(for segments: [MeasurementSegment]) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(segments.count * 3)
        for s in segments {
            pts.append(s.start)
            pts.append(s.midpoint)
            pts.append(s.end)
        }
        return pts
    }

    /// Endpoints only (polyline corner positions), for modes where the reticle should not snap to segment midpoints.
    static func endpointOnlyPinpointWorldPositions(for segments: [MeasurementSegment]) -> [SIMD3<Float>] {
        guard let first = segments.first else { return [] }
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(segments.count + 1)
        pts.append(first.start)
        for s in segments {
            pts.append(s.end)
        }
        return pts
    }
}
