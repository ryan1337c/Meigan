//
//  FlattenRectifiedEdgeAnalysis+Skeleton.swift
//  Meigan
//
//  Centerline / skeleton topology: rasterizes a contour polygon, thins it with Zhang–Suen,
//  and classifies the result as a closed loop, open stroke, or branching stroke so that
//  `perimeterMeters` can report centerline length instead of outer-contour perimeter.
//
//  NOTE: `centerlineMeasurement` is currently not called from `makeCandidate` (disabled for
//  performance; outer contour only). Kept intact so it can be re-enabled without rework.
//

import CoreGraphics

extension FlattenRectifiedEdgeAnalysis {

    /// Centerline / topology pipeline tunables. Kept separate from public tuning for now;
    /// promote into `FlattenShapeDetectionTuning` if exposed externally.
    private enum SkeletonConfig {
        /// Padding added around each contour's bbox before rasterizing into a local grid.
        static let polygonGridPaddingPixels: Int = 3
        /// Minimum filled foreground pixels inside the rasterized polygon to attempt classification.
        static let minimumPolygonPixelsForClassification: Int = 24
        /// Minimum skeleton pixels after thinning to attempt classification.
        static let minimumSkeletonPixelsForClassification: Int = 8
        /// Endpoint spurs shorter than this (skeleton pixels) are trimmed before topology counting.
        static let spurTrimMinPixels: CGFloat = 3
        /// Safety cap on thinning iterations.
        static let maxThinningIterations: Int = 200
    }

    // MARK: - Centerline / skeleton topology

    /// Result of attempting centerline classification on a contour's filled interior.
    struct CenterlineMeasurement {
        let warpedLength: CGFloat
        let kind: ShapeLengthKind
    }

    /// Rasterizes the contour polygon (in detection-space coordinates), thins it with
    /// Zhang–Suen, and returns a centerline length scaled to warped pixels along with the
    /// length kind. Returns `nil` when the shape is closed, too small, or otherwise
    /// ambiguous — callers should fall back to outer contour perimeter in that case.
    static func centerlineMeasurement(
        detectionLoop: [CGPoint],
        detectionWidth detW: Int,
        detectionHeight detH: Int,
        scaleToWarped: CGFloat
    ) -> CenterlineMeasurement? {
        guard detectionLoop.count >= 3 else { return nil }
        guard detW > 0, detH > 0 else { return nil }

        let bbox = boundingBox(of: detectionLoop)
        let pad = SkeletonConfig.polygonGridPaddingPixels
        let originX = max(0, Int(bbox.minX.rounded(.down)) - pad)
        let originY = max(0, Int(bbox.minY.rounded(.down)) - pad)
        let endX = min(detW, Int(bbox.maxX.rounded(.up)) + pad)
        let endY = min(detH, Int(bbox.maxY.rounded(.up)) + pad)
        let gridW = endX - originX
        let gridH = endY - originY
        guard gridW > 4, gridH > 4 else { return nil }

        var grid = [Bool](repeating: false, count: gridW * gridH)
        let foregroundCount = rasterizePolygon(
            detectionLoop,
            originX: originX,
            originY: originY,
            gridW: gridW,
            gridH: gridH,
            into: &grid
        )
        guard foregroundCount >= SkeletonConfig.minimumPolygonPixelsForClassification else {
            return nil
        }

        zhangSuenThin(&grid, width: gridW, height: gridH)
        trimShortSpurs(
            &grid,
            width: gridW,
            height: gridH,
            minSpurPixels: SkeletonConfig.spurTrimMinPixels
        )

        let topology = computeSkeletonTopology(grid: grid, width: gridW, height: gridH)
        guard topology.foregroundCount >= SkeletonConfig.minimumSkeletonPixelsForClassification else {
            return nil
        }

        // 0 endpoints → closed loop. Outer contour is the right measure (fallback).
        // 1 endpoint → degenerate (typically thinning noise). Fall back to outer contour.
        switch topology.endpointCount {
        case 0:
            return nil
        case 1:
            return nil
        case 2:
            // Simple open path only when there are no junctions; otherwise the "walk" has
            // ambiguous choices, so prefer total branch length for correctness.
            if topology.junctionCount == 0,
               let detectionLength = traceLengthBetweenEndpoints(
                   grid: grid,
                   width: gridW,
                   height: gridH,
                   endpoints: topology.endpoints
               )
            {
                return CenterlineMeasurement(
                    warpedLength: detectionLength * scaleToWarped,
                    kind: .openCenterline
                )
            }
            let total = totalSkeletonEdgeLength(grid: grid, width: gridW, height: gridH)
            guard total > 0 else { return nil }
            return CenterlineMeasurement(
                warpedLength: total * scaleToWarped,
                kind: .branchingCenterline
            )
        default:
            // 3+ endpoints: sum every skeleton edge once.
            let total = totalSkeletonEdgeLength(grid: grid, width: gridW, height: gridH)
            guard total > 0 else { return nil }
            return CenterlineMeasurement(
                warpedLength: total * scaleToWarped,
                kind: .branchingCenterline
            )
        }
    }

    /// Even–odd scanline polygon fill. Writes `true` into `grid` for filled pixels at
    /// `(x, y)` mapped into the local grid via `originX/originY`. Returns the number of
    /// filled pixels.
    @discardableResult
    private static func rasterizePolygon(
        _ points: [CGPoint],
        originX: Int,
        originY: Int,
        gridW: Int,
        gridH: Int,
        into grid: inout [Bool]
    ) -> Int {
        guard points.count >= 3 else { return 0 }
        let n = points.count
        var filled = 0

        for y in 0..<gridH {
            let yWorld = CGFloat(originY + y) + 0.5
            var crossings: [CGFloat] = []
            crossings.reserveCapacity(8)

            for i in 0..<n {
                let a = points[i]
                let b = points[(i + 1) % n]
                let cond1 = a.y <= yWorld && b.y > yWorld
                let cond2 = b.y <= yWorld && a.y > yWorld
                if !(cond1 || cond2) { continue }
                let dy = b.y - a.y
                guard abs(dy) > 1e-9 else { continue }
                let t = (yWorld - a.y) / dy
                let x = a.x + t * (b.x - a.x)
                crossings.append(x - CGFloat(originX))
            }

            guard crossings.count >= 2 else { continue }
            crossings.sort()

            var i = 0
            while i + 1 < crossings.count {
                let xStart = max(0, Int(crossings[i].rounded()))
                let xEnd = min(gridW, Int(crossings[i + 1].rounded()))
                if xStart < xEnd {
                    let base = y * gridW
                    for x in xStart..<xEnd where !grid[base + x] {
                        grid[base + x] = true
                        filled += 1
                    }
                }
                i += 2
            }
        }
        return filled
    }

    /// Zhang–Suen thinning: iteratively peels boundary pixels until the foreground is
    /// 1-pixel wide. Border rows/columns are skipped (they cannot have full neighborhoods).
    private static func zhangSuenThin(_ grid: inout [Bool], width: Int, height: Int) {
        guard width > 2, height > 2 else { return }
        var iteration = 0
        var changed = true

        while changed && iteration < SkeletonConfig.maxThinningIterations {
            changed = false
            for step in 0..<2 {
                var toRemove: [Int] = []
                for y in 1..<(height - 1) {
                    let rowBase = y * width
                    for x in 1..<(width - 1) {
                        let idx = rowBase + x
                        if !grid[idx] { continue }

                        // Neighbors p2..p9, clockwise starting from north.
                        let p2 = grid[(y - 1) * width + x]
                        let p3 = grid[(y - 1) * width + (x + 1)]
                        let p4 = grid[y * width + (x + 1)]
                        let p5 = grid[(y + 1) * width + (x + 1)]
                        let p6 = grid[(y + 1) * width + x]
                        let p7 = grid[(y + 1) * width + (x - 1)]
                        let p8 = grid[y * width + (x - 1)]
                        let p9 = grid[(y - 1) * width + (x - 1)]

                        var b = 0
                        if p2 { b += 1 }
                        if p3 { b += 1 }
                        if p4 { b += 1 }
                        if p5 { b += 1 }
                        if p6 { b += 1 }
                        if p7 { b += 1 }
                        if p8 { b += 1 }
                        if p9 { b += 1 }
                        if b < 2 || b > 6 { continue }

                        // Count 0→1 transitions around the cyclic neighborhood.
                        var a = 0
                        if !p2 && p3 { a += 1 }
                        if !p3 && p4 { a += 1 }
                        if !p4 && p5 { a += 1 }
                        if !p5 && p6 { a += 1 }
                        if !p6 && p7 { a += 1 }
                        if !p7 && p8 { a += 1 }
                        if !p8 && p9 { a += 1 }
                        if !p9 && p2 { a += 1 }
                        if a != 1 { continue }

                        if step == 0 {
                            if p2 && p4 && p6 { continue }
                            if p4 && p6 && p8 { continue }
                        } else {
                            if p2 && p4 && p8 { continue }
                            if p2 && p6 && p8 { continue }
                        }

                        toRemove.append(idx)
                    }
                }
                if !toRemove.isEmpty {
                    for idx in toRemove { grid[idx] = false }
                    changed = true
                }
            }
            iteration += 1
        }
    }

    /// 8-connected neighbor degree count for a single skeleton pixel.
    private static func skeletonDegree(grid: [Bool], width: Int, height: Int, x: Int, y: Int) -> Int {
        var d = 0
        for dy in -1...1 {
            let ny = y + dy
            if ny < 0 || ny >= height { continue }
            for dx in -1...1 {
                if dx == 0 && dy == 0 { continue }
                let nx = x + dx
                if nx < 0 || nx >= width { continue }
                if grid[ny * width + nx] { d += 1 }
            }
        }
        return d
    }

    /// Removes degree-1 spurs whose path length to the nearest junction or other endpoint
    /// is below `minSpurPixels`. Iterates until no more spurs are short enough to remove
    /// (junctions may collapse into endpoints, exposing new short spurs).
    private static func trimShortSpurs(
        _ grid: inout [Bool],
        width: Int,
        height: Int,
        minSpurPixels: CGFloat
    ) {
        guard minSpurPixels > 0 else { return }
        let sqrt2 = CGFloat(2).squareRoot()
        var passes = 0
        while passes < 12 {
            passes += 1
            var endpoints: [(x: Int, y: Int)] = []
            for y in 0..<height {
                let rowBase = y * width
                for x in 0..<width where grid[rowBase + x] {
                    if skeletonDegree(grid: grid, width: width, height: height, x: x, y: y) == 1 {
                        endpoints.append((x, y))
                    }
                }
            }
            if endpoints.isEmpty { return }

            var removedAny = false
            for ep in endpoints {
                if !grid[ep.y * width + ep.x] { continue }
                var path: [(x: Int, y: Int)] = [ep]
                var prev: (x: Int, y: Int) = (-1, -1)
                var current = ep
                var len: CGFloat = 0
                var stoppedAtSimpleEnd = false

                while len <= minSpurPixels {
                    var next: (x: Int, y: Int)? = nil
                    for dy in -1...1 {
                        let ny = current.y + dy
                        if ny < 0 || ny >= height { continue }
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            let nx = current.x + dx
                            if nx < 0 || nx >= width { continue }
                            if !grid[ny * width + nx] { continue }
                            if nx == prev.x && ny == prev.y { continue }
                            next = (nx, ny)
                            break
                        }
                        if next != nil { break }
                    }
                    guard let n = next else {
                        // Reached an isolated pixel run with no continuation.
                        stoppedAtSimpleEnd = true
                        break
                    }

                    let d = skeletonDegree(grid: grid, width: width, height: height, x: n.x, y: n.y)
                    if d != 2 {
                        // Reached a junction or another endpoint — stop without consuming `n`.
                        stoppedAtSimpleEnd = true
                        break
                    }
                    let stepLen = (n.x != current.x && n.y != current.y) ? sqrt2 : CGFloat(1)
                    len += stepLen
                    path.append(n)
                    prev = current
                    current = n
                }

                if stoppedAtSimpleEnd && len < minSpurPixels {
                    for p in path { grid[p.y * width + p.x] = false }
                    removedAny = true
                }
            }
            if !removedAny { return }
        }
    }

    /// Summary of skeleton topology used to pick a length metric.
    private struct SkeletonTopology {
        let foregroundCount: Int
        let endpointCount: Int
        let junctionCount: Int
        let endpoints: [(x: Int, y: Int)]
    }

    private static func computeSkeletonTopology(grid: [Bool], width: Int, height: Int) -> SkeletonTopology {
        var endpoints: [(x: Int, y: Int)] = []
        var junctions = 0
        var foreground = 0
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width where grid[rowBase + x] {
                foreground += 1
                let d = skeletonDegree(grid: grid, width: width, height: height, x: x, y: y)
                if d == 1 {
                    endpoints.append((x, y))
                } else if d >= 3 {
                    junctions += 1
                }
            }
        }
        return SkeletonTopology(
            foregroundCount: foreground,
            endpointCount: endpoints.count,
            junctionCount: junctions,
            endpoints: endpoints
        )
    }

    /// Walks the skeleton from one endpoint along the (assumed unique) path to the other,
    /// summing 1.0 for orthogonal neighbor steps and √2 for diagonal steps. Returns `nil`
    /// if the walk cannot reach the second endpoint (broken skeleton, junction confusion).
    /// Assumes the skeleton between the two endpoints has no degree-3+ junctions.
    private static func traceLengthBetweenEndpoints(
        grid: [Bool],
        width: Int,
        height: Int,
        endpoints: [(x: Int, y: Int)]
    ) -> CGFloat? {
        guard endpoints.count == 2 else { return nil }
        let start = endpoints[0]
        let target = endpoints[1]
        let sqrt2 = CGFloat(2).squareRoot()

        var visited = [Bool](repeating: false, count: width * height)
        visited[start.y * width + start.x] = true
        var current = start
        var prev: (x: Int, y: Int) = (-1, -1)
        var total: CGFloat = 0
        var steps = 0
        let maxSteps = width * height + 4

        while steps < maxSteps {
            if current.x == target.x && current.y == target.y {
                return total
            }
            var next: (x: Int, y: Int)? = nil
            for dy in -1...1 {
                let ny = current.y + dy
                if ny < 0 || ny >= height { continue }
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let nx = current.x + dx
                    if nx < 0 || nx >= width { continue }
                    if visited[ny * width + nx] { continue }
                    if !grid[ny * width + nx] { continue }
                    if nx == prev.x && ny == prev.y { continue }
                    next = (nx, ny)
                    break
                }
                if next != nil { break }
            }
            guard let n = next else { return nil }
            let stepLen = (n.x != current.x && n.y != current.y) ? sqrt2 : CGFloat(1)
            total += stepLen
            visited[n.y * width + n.x] = true
            prev = current
            current = n
            steps += 1
        }
        return nil
    }

    /// Sum of every unique 8-connected edge in the skeleton. Each adjacency is counted once
    /// by only crediting neighbors whose flattened index is greater than the current pixel's.
    private static func totalSkeletonEdgeLength(grid: [Bool], width: Int, height: Int) -> CGFloat {
        let sqrt2 = CGFloat(2).squareRoot()
        var total: CGFloat = 0
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width where grid[rowBase + x] {
                let currentIdx = rowBase + x
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let nIdx = ny * width + nx
                        if nIdx <= currentIdx { continue }
                        if !grid[nIdx] { continue }
                        total += (dx == 0 || dy == 0) ? CGFloat(1) : sqrt2
                    }
                }
            }
        }
        return total
    }
}
