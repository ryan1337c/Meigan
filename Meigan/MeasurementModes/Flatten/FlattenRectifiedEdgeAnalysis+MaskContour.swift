//
//  FlattenRectifiedEdgeAnalysis+MaskContour.swift
//  Meigan
//
//  Sub-pixel outer contour of a soft instance mask: marching squares at iso 0.5 with linear
//  edge interpolation, chained into closed loops. The largest loop becomes the shape's
//  contour, and its perimeter skips stretches that run along the image frame.
//

import CoreGraphics

extension FlattenRectifiedEdgeAnalysis {

    // MARK: - Constants

    /// Mask value treated as the object boundary.
    private static let maskIsoLevel: Float = 0.5

    /// Where an instance is cut off by the frame, the iso crossing falls between the
    /// out-of-bounds 0 sample and the first in-bounds pixel center, so it lands within half a
    /// pixel of the frame edge.
    private static let frameEdgeTolerance: CGFloat = 0.5 + 1e-3

    private enum CellEdge {
        case top
        case right
        case bottom
        case left
    }

    // MARK: - Candidate

    /// Traces `mask` into a candidate, or returns nil when the contour fails the area filters.
    static func makeCandidate(
        from mask: FlattenSoftMask,
        imageBounds: CGRect,
        tuning: FlattenShapeDetectionTuning
    ) -> ShapeCandidate? {
        let imageArea = imageBounds.width * imageBounds.height
        guard imageArea > 0, let loop = outerContour(of: mask) else { return nil }

        guard abs(signedArea(of: loop)) >= imageArea * tuning.minimumObjectAreaFraction else { return nil }

        let bounds = boundingBox(of: loop).intersection(imageBounds)
        guard !bounds.isNull, bounds.width >= 2, bounds.height >= 2 else { return nil }
        if tuning.maxBoundingBoxAreaFraction < 1,
           bounds.width * bounds.height / imageArea >= tuning.maxBoundingBoxAreaFraction {
            return nil
        }

        let perimeter = visibleContourLength(of: loop, imageBounds: imageBounds)
        guard perimeter > 0, let dimensions = orientedDimensions(of: loop) else { return nil }

        return ShapeCandidate(
            contourImage: loop,
            boundingRectImage: bounds,
            widthSegment: dimensions.widthSegment,
            heightSegment: dimensions.heightSegment,
            orientationRadians: dimensions.orientationRadians,
            perimeterPixels: perimeter,
            lengthKind: .outerContour
        )
    }

    // MARK: - Contour

    /// Closed outer contour of `mask` in warped pixels, with the first point repeated at the end.
    /// Holes and smaller islands are dropped.
    static func outerContour(of mask: FlattenSoftMask) -> [CGPoint]? {
        var largestLoop: [CGPoint]?
        var largestArea: CGFloat = 0
        for loop in isoContourLoops(of: mask) {
            let area = abs(signedArea(of: loop))
            if area > largestArea {
                largestArea = area
                largestLoop = loop
            }
        }
        guard let loop = largestLoop, let first = loop.first else { return nil }
        return loop + [first]
    }

    /// All closed iso-0.5 loops of `mask`, oriented clockwise on screen around the foreground.
    ///
    /// Samples sit at pixel centers. The scan covers the stored region plus a 1-sample ring of
    /// zeros, so every loop closes, including those touching the image frame.
    private static func isoContourLoops(of mask: FlattenSoftMask) -> [[CGPoint]] {
        let gridWidth = mask.width + 2
        let gridHeight = mask.height + 2
        let iso = maskIsoLevel
        let originX = CGFloat(mask.originX) - 0.5
        let originY = CGFloat(mask.originY) - 0.5

        return mask.values.withUnsafeBufferPointer { values in
            @inline(__always)
            func sample(_ gx: Int, _ gy: Int) -> Float {
                let lx = gx - 1
                let ly = gy - 1
                guard lx >= 0, ly >= 0, lx < mask.width, ly < mask.height else { return 0 }
                return values[ly * mask.width + lx]
            }

            // Horizontal edges get even keys and vertical edges odd keys, indexed by their
            // top-left sample.
            func edgeKey(_ edge: CellEdge, gx: Int, gy: Int) -> Int {
                switch edge {
                case .top: return (gy * gridWidth + gx) * 2
                case .bottom: return ((gy + 1) * gridWidth + gx) * 2
                case .left: return (gy * gridWidth + gx) * 2 + 1
                case .right: return (gy * gridWidth + gx + 1) * 2 + 1
                }
            }

            func crossingPoint(forEdgeKey key: Int) -> CGPoint {
                let isVertical = key & 1 == 1
                let index = key >> 1
                let gx = index % gridWidth
                let gy = index / gridWidth
                let a = sample(gx, gy)
                let b = isVertical ? sample(gx, gy + 1) : sample(gx + 1, gy)
                let t = CGFloat((iso - a) / (b - a))
                let x = CGFloat(gx) + (isVertical ? 0 : t)
                let y = CGFloat(gy) + (isVertical ? t : 0)
                return CGPoint(x: originX + x, y: originY + y)
            }

            var nextEdgeKey: [Int: Int] = [:]
            for gy in 0..<(gridHeight - 1) {
                for gx in 0..<(gridWidth - 1) {
                    let topLeft = sample(gx, gy)
                    let topRight = sample(gx + 1, gy)
                    let bottomRight = sample(gx + 1, gy + 1)
                    let bottomLeft = sample(gx, gy + 1)

                    var caseIndex = 0
                    if topLeft >= iso { caseIndex |= 1 }
                    if topRight >= iso { caseIndex |= 2 }
                    if bottomRight >= iso { caseIndex |= 4 }
                    if bottomLeft >= iso { caseIndex |= 8 }
                    guard caseIndex != 0, caseIndex != 15 else { continue }

                    let isCenterInside = (topLeft + topRight + bottomRight + bottomLeft) / 4 >= iso
                    for (from, to) in cellSegments(caseIndex: caseIndex, isCenterInside: isCenterInside) {
                        nextEdgeKey[edgeKey(from, gx: gx, gy: gy)] = edgeKey(to, gx: gx, gy: gy)
                    }
                }
            }

            var visited = Set<Int>(minimumCapacity: nextEdgeKey.count)
            var loops: [[CGPoint]] = []
            for start in nextEdgeKey.keys where !visited.contains(start) {
                var loop: [CGPoint] = []
                var key = start
                var isClosed = false
                while visited.insert(key).inserted {
                    loop.append(crossingPoint(forEdgeKey: key))
                    guard let following = nextEdgeKey[key] else { break }
                    if following == start {
                        isClosed = true
                        break
                    }
                    key = following
                }
                if isClosed, loop.count >= 3 {
                    loops.append(loop)
                }
            }
            return loops
        }
    }

    /// Oriented segments for one cell. Corner bits are top-left 1, top-right 2, bottom-right 4,
    /// bottom-left 8. Each segment keeps the foreground on its right in image coordinates, so
    /// every crossing has exactly one outgoing segment. Saddles (5, 10) join the inside corners
    /// through the center only when the cell average is inside.
    private static func cellSegments(caseIndex: Int, isCenterInside: Bool) -> [(CellEdge, CellEdge)] {
        switch caseIndex {
        case 1: return [(.top, .left)]
        case 2: return [(.right, .top)]
        case 3: return [(.right, .left)]
        case 4: return [(.bottom, .right)]
        case 5:
            return isCenterInside
                ? [(.top, .right), (.bottom, .left)]
                : [(.top, .left), (.bottom, .right)]
        case 6: return [(.bottom, .top)]
        case 7: return [(.bottom, .left)]
        case 8: return [(.left, .bottom)]
        case 9: return [(.top, .bottom)]
        case 10:
            return isCenterInside
                ? [(.left, .top), (.right, .bottom)]
                : [(.right, .top), (.left, .bottom)]
        case 11: return [(.right, .bottom)]
        case 12: return [(.left, .right)]
        case 13: return [(.top, .right)]
        case 14: return [(.left, .top)]
        default: return []
        }
    }

    // MARK: - Measurements

    /// Shoelace area of `loop`. Works whether or not the first point is repeated at the end.
    static func signedArea(of loop: [CGPoint]) -> CGFloat {
        guard loop.count >= 3 else { return 0 }
        var twiceArea: CGFloat = 0
        for i in loop.indices {
            let a = loop[i]
            let b = loop[(i + 1) % loop.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        return twiceArea / 2
    }

    /// Length of a closed `loop` (first point repeated at the end), excluding segments that
    /// lie along the image frame so the perimeter tracks visible ink only.
    static func visibleContourLength(of loop: [CGPoint], imageBounds: CGRect) -> CGFloat {
        guard loop.count >= 2 else { return 0 }
        var length: CGFloat = 0
        for i in 0..<(loop.count - 1) {
            let a = loop[i]
            let b = loop[i + 1]
            guard !isAlongFrame(a, b, imageBounds: imageBounds) else { continue }
            length += hypot(b.x - a.x, b.y - a.y)
        }
        return length
    }

    private static func isAlongFrame(_ a: CGPoint, _ b: CGPoint, imageBounds: CGRect) -> Bool {
        func areNear(_ edge: CGFloat, _ u: CGFloat, _ v: CGFloat) -> Bool {
            abs(u - edge) <= frameEdgeTolerance && abs(v - edge) <= frameEdgeTolerance
        }
        return areNear(imageBounds.minX, a.x, b.x)
            || areNear(imageBounds.maxX, a.x, b.x)
            || areNear(imageBounds.minY, a.y, b.y)
            || areNear(imageBounds.maxY, a.y, b.y)
    }
}
