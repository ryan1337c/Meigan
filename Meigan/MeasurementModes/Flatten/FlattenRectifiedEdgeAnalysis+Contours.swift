//
//  FlattenRectifiedEdgeAnalysis+Contours.swift
//  Meigan
//
//  Vision contour request, per-contour candidate extraction, fragment merging, and the
//  2D geometry helpers (bounding boxes, polyline clipping) they depend on.
//

import CoreGraphics
import Vision

extension FlattenRectifiedEdgeAnalysis {

    // MARK: - Vision

    static func runContourRequest(on detectionCGImage: CGImage, tuning: FlattenShapeDetectionTuning) -> VNContoursObservation? {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = tuning.visionContrastAdjustment
        request.detectsDarkOnLight = true
        request.maximumImageDimension = max(detectionCGImage.width, detectionCGImage.height)

        let handler = VNImageRequestHandler(cgImage: detectionCGImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNContoursObservation
        } catch {
            return nil
        }
    }

    /// Top-level Vision contours only — skips nested `childContours` (grip ribs, inner holes, etc.).
    static func topLevelContours(from observation: VNContoursObservation) -> [VNContour] {
        observation.topLevelContours
    }

    static func makeCandidate(
        from contour: VNContour,
        detectionWidth: CGFloat,
        detectionHeight: CGFloat,
        scaleToWarped: CGFloat,
        imageBounds: CGRect,
        tuning: FlattenShapeDetectionTuning
    ) -> ShapeCandidate? {
        let detW = Int(detectionWidth)
        let detH = Int(detectionHeight)
        guard detW > 0, detH > 0 else { return nil }

        let path = contour.normalizedPath
        var rawVisionPoints: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                rawVisionPoints.append(element.pointee.points[0])
            case .addQuadCurveToPoint:
                rawVisionPoints.append(element.pointee.points[1])
            case .addCurveToPoint:
                rawVisionPoints.append(element.pointee.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        guard rawVisionPoints.count >= 3 else { return nil }

        // Vision pixel coords (origin bottom-left) → detection bitmap coords (origin top-left)
        // → warped top-left pixels.
        var warpedPoints: [CGPoint] = []
        warpedPoints.reserveCapacity(rawVisionPoints.count)
        for n in rawVisionPoints {
            let p = VNImagePointForNormalizedPoint(n, detW, detH)
            let detX = p.x
            let detY = CGFloat(detH) - p.y
            warpedPoints.append(CGPoint(x: detX * scaleToWarped, y: detY * scaleToWarped))
        }

        let loop = closedPointLoop(warpedPoints)
        guard loop.count >= 3 else { return nil }

        let rawAABB = boundingBox(of: loop)
        let clippedRect = rawAABB.intersection(imageBounds)
        guard clippedRect.width >= 2, clippedRect.height >= 2,
              clippedRect.width * clippedRect.height >= tuning.minimumClippedBoundingBoxAreaPixels
        else { return nil }

        // Drop background / image-frame contours that span (almost) the whole warped bitmap.
        let imageArea = imageBounds.width * imageBounds.height
        if imageArea > 0, tuning.maxBoundingBoxAreaFraction < 1 {
            let areaFraction = (clippedRect.width * clippedRect.height) / imageArea
            if areaFraction >= tuning.maxBoundingBoxAreaFraction { return nil }
        }

        let outerContourPx = visiblePolylineLength(in: imageBounds, closed: true, points: loop)
        guard outerContourPx > 0 else { return nil }

        // Outer contour only. Centerline classification via the Zhang–Suen skeleton
        // (`centerlineMeasurement` in `+Skeleton.swift`) is intentionally not wired in for
        // performance; re-enable by mapping `rawVisionPoints` to detection-space and calling it here.
        return ShapeCandidate(
            boundingRectImage: clippedRect,
            perimeterPixels: outerContourPx,
            lengthKind: .outerContour
        )
    }

    private static func mergeCandidates(
        _ candidates: [ShapeCandidate],
        imageBounds: CGRect,
        tuning: FlattenShapeDetectionTuning
    ) -> [ShapeCandidate] {
        guard !candidates.isEmpty else { return [] }
        let padding = max(imageBounds.width, imageBounds.height) * tuning.mergePaddingFractionOfLongestEdge
        var merged: [ShapeCandidate] = []

        for candidate in candidates.sorted(by: { area(of: $0.boundingRectImage) > area(of: $1.boundingRectImage) }) {
            var current = candidate
            var didMerge = true
            while didMerge {
                didMerge = false
                for index in merged.indices.reversed() {
                    let expandedCurrent = current.boundingRectImage.insetBy(dx: -padding, dy: -padding)
                    let expandedExisting = merged[index].boundingRectImage.insetBy(dx: -padding, dy: -padding)
                    guard expandedCurrent.intersects(expandedExisting) else { continue }
                    // Keep the larger candidate's length kind; sum perimeters (existing behavior).
                    let currentArea = area(of: current.boundingRectImage)
                    let existingArea = area(of: merged[index].boundingRectImage)
                    if existingArea > currentArea {
                        current.lengthKind = merged[index].lengthKind
                    }
                    current.boundingRectImage = current.boundingRectImage.union(merged[index].boundingRectImage).intersection(imageBounds)
                    current.perimeterPixels += merged[index].perimeterPixels
                    merged.remove(at: index)
                    didMerge = true
                }
            }
            merged.append(current)
        }

        return merged
    }

    static func makeFindings(
        from candidates: [ShapeCandidate],
        imageBounds: CGRect,
        pixelsPerMeter: Float,
        tuning: FlattenShapeDetectionTuning
    ) -> [FlattenShapeFinding] {
        let ppm = CGFloat(pixelsPerMeter)
        let imageArea = area(of: imageBounds)
        let minimumObjectArea = max(
            tuning.minimumClippedBoundingBoxAreaPixels,
            imageArea * tuning.minimumObjectAreaFraction
        )

        let mergedCandidates = mergeCandidates(candidates, imageBounds: imageBounds, tuning: tuning)

        return mergedCandidates.compactMap { candidate in
            let clippedRect = candidate.boundingRectImage.intersection(imageBounds)
            let rectArea = area(of: clippedRect)
            guard clippedRect.width >= 2, clippedRect.height >= 2,
                  rectArea >= minimumObjectArea
            else { return nil }

            let norm = CGRect(
                x: clippedRect.minX / imageBounds.width,
                y: clippedRect.minY / imageBounds.height,
                width: clippedRect.width / imageBounds.width,
                height: clippedRect.height / imageBounds.height
            )

            return FlattenShapeFinding(
                id: UUID(),
                boundingRectImage: clippedRect,
                boundingRectNormalized: norm,
                widthMeters: Float(clippedRect.width / ppm),
                heightMeters: Float(clippedRect.height / ppm),
                perimeterMeters: Float(candidate.perimeterPixels / ppm),
                lengthKind: candidate.lengthKind
            )
        }
    }

    // MARK: - Geometry

    private static func area(of rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        return rect.width * rect.height
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func closedPointLoop(_ pts: [CGPoint]) -> [CGPoint] {
        guard let first = pts.first else { return [] }
        if let last = pts.last, hypot(last.x - first.x, last.y - first.y) < 1e-3 {
            return pts
        }
        return pts + [first]
    }

    /// Total length of `points` after clipping each segment to `bounds`. When `closed`, includes segment last→first.
    private static func visiblePolylineLength(in bounds: CGRect, closed: Bool, points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var sum: CGFloat = 0
        let n = points.count
        for i in 0..<(n - 1) {
            let a = points[i]
            let b = points[closed ? ((i + 1) % n) : (i + 1)]
            if let clipped = clipSegmentToRect(a, b, bounds) {
                sum += hypot(clipped.1.x - clipped.0.x, clipped.1.y - clipped.0.y)
            }
        }
        return sum
    }

    /// Cohen–Sutherland; returns nil if the segment is outside `rect`.
    private static func clipSegmentToRect(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> (CGPoint, CGPoint)? {
        var x0 = a.x
        var y0 = a.y
        var x1 = b.x
        var y1 = b.y

        let xmin = rect.minX
        let ymin = rect.minY
        let xmax = rect.maxX
        let ymax = rect.maxY

        func code(_ x: CGFloat, _ y: CGFloat) -> Int {
            var c = 0
            if x < xmin { c |= 1 }
            else if x > xmax { c |= 2 }
            if y < ymin { c |= 4 }
            else if y > ymax { c |= 8 }
            return c
        }

        var c0 = code(x0, y0)
        var c1 = code(x1, y1)

        while true {
            if (c0 | c1) == 0 { return (CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)) }
            if (c0 & c1) != 0 { return nil }

            let c = c0 != 0 ? c0 : c1
            var x: CGFloat = 0
            var y: CGFloat = 0
            var advanced = false

            if (c & 8) != 0, abs(y1 - y0) > 1e-12 {
                x = x0 + (x1 - x0) * (ymax - y0) / (y1 - y0)
                y = ymax
                advanced = true
            } else if (c & 4) != 0, abs(y1 - y0) > 1e-12 {
                x = x0 + (x1 - x0) * (ymin - y0) / (y1 - y0)
                y = ymin
                advanced = true
            } else if (c & 2) != 0, abs(x1 - x0) > 1e-12 {
                y = y0 + (y1 - y0) * (xmax - x0) / (x1 - x0)
                x = xmax
                advanced = true
            } else if (c & 1) != 0, abs(x1 - x0) > 1e-12 {
                y = y0 + (y1 - y0) * (xmin - x0) / (x1 - x0)
                x = xmin
                advanced = true
            }

            if !advanced { return nil }

            if c == c0 {
                x0 = x
                y0 = y
                c0 = code(x0, y0)
            } else {
                x1 = x
                y1 = y
                c1 = code(x1, y1)
            }
        }
    }
}
