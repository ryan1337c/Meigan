//
//  FlattenRectifiedEdgeAnalysis.swift
//  Meigan
//
//  Detection-only pipeline: builds a temporary grayscale / edge-enhanced Core Image render
//  from a copy of the rectified photo for Vision contour detection. The original `UIImage`
//  used for display is never modified or substituted.
//

import CoreGraphics
import CoreImage
import UIKit
import Vision

/// One closed region discovered on the rectified (warped) bitmap, with geometry expressed
/// in the warped image’s pixel space (origin top-left, matching SwiftUI `Image` layout).
struct FlattenShapeFinding: Equatable, Sendable, Identifiable {
    let id: UUID
    /// Axis-aligned bounds intersected with `0…width × 0…height` of the warped image.
    let boundingRectImage: CGRect
    /// Derived from `boundingRectImage` for overlay layout (optional convenience).
    let boundingRectNormalized: CGRect
    let widthMeters: Float
    let heightMeters: Float
    /// Visible edge length after clipping segments to the image rect (see implementation note).
    let perimeterMeters: Float
}

/// Thresholds and caps for the Vision + Core Image contour pipeline (`FlattenRectifiedEdgeAnalysis`).
struct FlattenShapeDetectionTuning: Equatable, Sendable {
    /// Longest edge of the bitmap passed into Vision (smaller = faster; coordinates map back to full warped size).
    var detectionMaxLongestEdge: CGFloat
    /// Extra contrast applied to the grayscale analysis image before Vision contour detection.
    var analysisContrastBoost: Float
    /// `VNDetectContoursRequest.contrastAdjustment` — higher can pull fainter strokes at the cost of noise.
    var visionContrastAdjustment: Float
    /// Minimum clipped bounding-box area (px²) in warped space to keep a raw contour fragment.
    var minimumClippedBoundingBoxAreaPixels: CGFloat
    /// Minimum merged object bbox area as a fraction of the warped image area.
    var minimumObjectAreaFraction: CGFloat
    /// Reject contours whose clipped bbox covers at least this fraction of the warped image area.
    /// `VNDetectContoursRequest` typically emits one huge contour around the whole frame; this drops it.
    /// Range `(0, 1]`; `1` disables the upper bound.
    var maxBoundingBoxAreaFraction: CGFloat
    /// Merge contour fragments whose boxes intersect after expanding by this fraction of the image's longest edge.
    var mergePaddingFractionOfLongestEdge: CGFloat
    /// Ramer–Douglas–Peucker tolerance in **warped** pixels (larger = fewer vertices).
    var simplifyEpsilonWarpedPixels: CGFloat
    /// After filtering, keep at most this many shapes by descending clipped bbox area (`0` = unlimited).
    var maxReturnedShapes: Int

    static let `default` = FlattenShapeDetectionTuning(
        detectionMaxLongestEdge: 960,
        analysisContrastBoost: 0.35,
        visionContrastAdjustment: 1.2,
        minimumClippedBoundingBoxAreaPixels: 48,
        minimumObjectAreaFraction: 0.003,
        maxBoundingBoxAreaFraction: 0.88,
        mergePaddingFractionOfLongestEdge: 0.035,
        simplifyEpsilonWarpedPixels: 2,
        maxReturnedShapes: 32
    )
}

/// Contour-driven shape discovery on the birds-eye `UIImage` from `inverseWarpQuadImage`.
enum FlattenRectifiedEdgeAnalysis {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private struct ShapeCandidate {
        var boundingRectImage: CGRect
        var perimeterPixels: CGFloat
    }

    // MARK: - Public

    /// Runs contour detection on a CI-derived edge map; returns shapes in **warped** pixel coordinates.
    ///
    /// - Parameters:
    ///   - warpedImage: Full-color rectified bitmap shown in the UI (read-only).
    ///   - pixelsPerMeter: From `FlattenMeasurementMode.FlattenScanAnalysis.pixelsPerMeter`.
    ///   - tuning: Contour / edge thresholds and max shape count; use ``FlattenShapeDetectionTuning/default`` unless experimenting.
    /// - Note: `perimeterMeters` sums only portions of the simplified contour segments that lie inside the image bounds, so values track visible ink when a stroke touches the frame edge.
    static func shapeFindings(
        for warpedImage: UIImage,
        pixelsPerMeter: Float,
        tuning: FlattenShapeDetectionTuning = .default
    ) -> [FlattenShapeFinding] {
        guard pixelsPerMeter > 1e-6,
              let cgImage = warpedImage.cgImage
        else { return [] }

        let fullWidth = CGFloat(cgImage.width)
        let fullHeight = CGFloat(cgImage.height)
        let imageBounds = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard fullWidth >= 8, fullHeight >= 8 else { return [] }

        guard let detection = makeDetectionCGImage(from: cgImage, tuning: tuning) else {
            return []
        }

        let detW = CGFloat(detection.width)
        let detH = CGFloat(detection.height)
        let scaleToWarped = fullWidth / detW

        guard let observation = runContourRequest(on: detection, tuning: tuning) else { return [] }

        var candidates: [ShapeCandidate] = []
        for contour in flattenedContours(from: observation) {
            guard let candidate = makeCandidate(
                from: contour,
                detectionWidth: detW,
                detectionHeight: detH,
                scaleToWarped: scaleToWarped,
                imageBounds: imageBounds,
                tuning: tuning
            ) else { continue }
            candidates.append(candidate)
        }

        let findings = makeFindings(
            from: mergeCandidates(candidates, imageBounds: imageBounds, tuning: tuning),
            imageBounds: imageBounds,
            pixelsPerMeter: pixelsPerMeter,
            tuning: tuning
        )

        // Deterministic ordering: larger visible boxes first (stable for UI); `maxReturnedShapes` keeps the largest N.
        var sortedFindings = findings.sorted {
            let a = $0.boundingRectImage.width * $0.boundingRectImage.height
            let b = $1.boundingRectImage.width * $1.boundingRectImage.height
            if a != b { return a > b }
            return $0.id.uuidString < $1.id.uuidString
        }
        if tuning.maxReturnedShapes > 0, sortedFindings.count > tuning.maxReturnedShapes {
            sortedFindings = Array(sortedFindings.prefix(tuning.maxReturnedShapes))
        }
        return sortedFindings
    }

    // MARK: - CI detection image (never shown)

    /// Renders a single-channel / edge-strengthened copy for Vision only.
    private static func makeDetectionCGImage(from cgImage: CGImage, tuning: FlattenShapeDetectionTuning) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }

        let longest = max(extent.width, extent.height)
        let scale: CGFloat
        if longest > tuning.detectionMaxLongestEdge, longest > 0 {
            scale = tuning.detectionMaxLongestEdge / longest
        } else {
            scale = 1
        }

        let detW = max(1, Int((extent.width * scale).rounded(.down)))
        let detH = max(1, Int((extent.height * scale).rounded(.down)))
        let scaleX = CGFloat(detW) / extent.width
        let scaleY = CGFloat(detH) / extent.height
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let mono = scaled.applyingFilter("CIPhotoEffectMono", parameters: [:])
        let contrast = mono.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1 + tuning.analysisContrastBoost
            ]
        )
        // Median filtering calms camera noise without replacing the displayed color bitmap.
        let blurred = contrast.applyingFilter("CIMedianFilter", parameters: [:])

        let outRect = CGRect(x: 0, y: 0, width: detW, height: detH)
        return ciContext.createCGImage(blurred, from: outRect)
    }

    // MARK: - Vision

    private static func runContourRequest(on detectionCGImage: CGImage, tuning: FlattenShapeDetectionTuning) -> VNContoursObservation? {
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

    private static func flattenedContours(from observation: VNContoursObservation) -> [VNContour] {
        var list: [VNContour] = []
        func visit(_ c: VNContour) {
            list.append(c)
            for child in c.childContours {
                visit(child)
            }
        }
        for root in observation.topLevelContours {
            visit(root)
        }
        return list
    }

    private static func makeCandidate(
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

        // Vision pixel coords (origin bottom-left) → detection bitmap coords → warped top-left pixels.
        var warpedPoints: [CGPoint] = []
        warpedPoints.reserveCapacity(rawVisionPoints.count)
        for n in rawVisionPoints {
            let p = VNImagePointForNormalizedPoint(n, detW, detH)
            let xWarped = p.x * scaleToWarped
            let yWarped = (CGFloat(detH) - p.y) * scaleToWarped
            warpedPoints.append(CGPoint(x: xWarped, y: yWarped))
        }

        let simplified = simplifyClosedPolygon(warpedPoints, epsilon: tuning.simplifyEpsilonWarpedPixels)
        let loop = closedPointLoop(simplified)
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

        let perimeterPx = visiblePolylineLength(in: imageBounds, closed: true, points: loop)
        guard perimeterPx > 0 else { return nil }

        return ShapeCandidate(boundingRectImage: clippedRect, perimeterPixels: perimeterPx)
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

    private static func makeFindings(
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

        return candidates.compactMap { candidate in
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
                perimeterMeters: Float(candidate.perimeterPixels / ppm)
            )
        }
    }

    // MARK: - Geometry

    private static func area(of rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        return rect.width * rect.height
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
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

    /// Ramer–Douglas–Peucker on an implicitly closed ring (drops duplicate closing vertex before simplify).
    private static func simplifyClosedPolygon(_ ring: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard ring.count > 2 else { return ring }
        var open = ring
        if let f = open.first, let l = open.last, hypot(l.x - f.x, l.y - f.y) < 1e-3 {
            open.removeLast()
        }
        guard open.count > 2 else { return ring }
        let simplifiedOpen = rdp(open, epsilon: epsilon)
        return simplifiedOpen
    }

    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var first = 0
        var last = points.count - 1
        var indices = Set<Int>([first, last])
        var stack: [(Int, Int)] = [(first, last)]

        while let range = stack.popLast() {
            first = range.0
            last = range.1
            var maxDist: CGFloat = 0
            var index = 0
            let a = points[first]
            let b = points[last]
            for i in (first + 1)..<last {
                let d = perpendicularDistance(points[i], lineStart: a, lineEnd: b)
                if d > maxDist {
                    index = i
                    maxDist = d
                }
            }
            if maxDist > epsilon {
                indices.insert(index)
                stack.append((first, index))
                stack.append((index, last))
            }
        }

        return points.indices.filter { indices.contains($0) }.map { points[$0] }
    }

    private static func perpendicularDistance(_ p: CGPoint, lineStart a: CGPoint, lineEnd b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-18 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
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
