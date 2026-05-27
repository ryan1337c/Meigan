//
//  FlattenRectifiedEdgeAnalysis.swift
//  Meigan
//
//  Detection-only pipeline. On iOS 17+, runs `VNGenerateForegroundInstanceMaskRequest`
//  to obtain a clean binary subject mask, then traces contours on that mask. On earlier
//  systems (or if the ML request fails), falls back to a grayscale + contrast + median
//  preprocessing pass. The original `UIImage` used for display is never modified.
//

import CoreGraphics
import CoreImage
import UIKit
import Vision

/// How `perimeterMeters` was measured for a given shape.
///
/// Determined by the skeleton topology of the detected blob after Zhang–Suen thinning:
/// - `outerContour`: 0 endpoints (closed loop) or rejected / fallback. Length is the outer
///   contour polyline length, as before.
/// - `openCenterline`: exactly 2 endpoints and no junctions. Length is walked along the
///   skeleton path from one endpoint to the other.
/// - `branchingCenterline`: 3+ endpoints, or 2 endpoints with junctions. Length is the
///   total sum of every skeleton edge (all branches combined).
enum ShapeLengthKind: String, Equatable, Sendable {
    case outerContour
    case openCenterline
    case branchingCenterline
}

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
    /// Outer contour perimeter for closed shapes, or centerline path length for open/branching
    /// strokes. See `lengthKind` for which measurement produced this value.
    let perimeterMeters: Float
    /// Indicates whether `perimeterMeters` is an outer contour perimeter or a centerline length.
    let lengthKind: ShapeLengthKind
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
    // var simplifyEpsilonWarpedPixels: CGFloat
    /// After filtering, keep at most this many shapes by descending clipped bbox area (`0` = unlimited).
    var maxReturnedShapes: Int

    static let `default` = FlattenShapeDetectionTuning(
        detectionMaxLongestEdge: 960,
        analysisContrastBoost: 0.35,
        visionContrastAdjustment: 1.2,
        minimumClippedBoundingBoxAreaPixels: 200,
        minimumObjectAreaFraction: 0.008,
        maxBoundingBoxAreaFraction: 0.88,
        mergePaddingFractionOfLongestEdge: 0.035,
        maxReturnedShapes: 32
    )
}

/// Contour detection output plus the bitmap fed to Vision (for tuning / debug).
struct FlattenShapeDetectionResult: Sendable {
    let findings: [FlattenShapeFinding]
    /// Binary ML subject mask on iOS 17+, or mono+contrast+median fallback on older systems.
    /// Never shown in the main UI.
    let detectionPreviewImage: UIImage?
}

/// Contour-driven shape discovery on the birds-eye `UIImage` from `inverseWarpQuadImage`.
enum FlattenRectifiedEdgeAnalysis {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private struct ShapeCandidate {
        var boundingRectImage: CGRect
        var perimeterPixels: CGFloat
        var lengthKind: ShapeLengthKind
    }

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
        detectShapes(for: warpedImage, pixelsPerMeter: pixelsPerMeter, tuning: tuning).findings
    }

    static func detectShapes(
        for warpedImage: UIImage,
        pixelsPerMeter: Float,
        tuning: FlattenShapeDetectionTuning = .default
    ) -> FlattenShapeDetectionResult {
        guard pixelsPerMeter > 1e-6,
              let cgImage = warpedImage.cgImage
        else {
            return FlattenShapeDetectionResult(findings: [], detectionPreviewImage: nil)
        }

        let fullWidth = CGFloat(cgImage.width)
        let fullHeight = CGFloat(cgImage.height)
        let imageBounds = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard fullWidth >= 8, fullHeight >= 8 else {
            return FlattenShapeDetectionResult(findings: [], detectionPreviewImage: nil)
        }

        guard let detection = makeDetectionCGImage(from: cgImage, tuning: tuning) else {
            return FlattenShapeDetectionResult(findings: [], detectionPreviewImage: nil)
        }

        let detectionPreviewImage = UIImage(cgImage: detection)

        let detW = CGFloat(detection.width)
        let detH = CGFloat(detection.height)
        let scaleToWarped = fullWidth / detW

        guard let observation = runContourRequest(on: detection, tuning: tuning) else {
            return FlattenShapeDetectionResult(findings: [], detectionPreviewImage: detectionPreviewImage)
        }

        var candidates: [ShapeCandidate] = []
        for contour in topLevelContours(from: observation) {
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
            from: candidates,
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
        return FlattenShapeDetectionResult(
            findings: sortedFindings,
            detectionPreviewImage: detectionPreviewImage
        )
    }

    // MARK: - Detection image (never shown)

    /// Returns a single-channel CGImage with dark foreground on light background, suitable for
    /// `VNDetectContoursRequest`. Prefers the ML subject mask on iOS 17+, falls back to grayscale.
    private static func makeDetectionCGImage(from cgImage: CGImage, tuning: FlattenShapeDetectionTuning) -> CGImage? {
        if #available(iOS 17.0, *) {
            if let masked = makeForegroundMaskDetectionCGImage(from: cgImage, tuning: tuning) {
                return masked
            }
        }
        return makeGrayscaleDetectionCGImage(from: cgImage, tuning: tuning)
    }

    /// Computes the scaled detection extent and a downscaled CIImage shared by both detection paths.
    private static func scaledDetectionCIImage(
        from cgImage: CGImage,
        tuning: FlattenShapeDetectionTuning
    ) -> (ciImage: CIImage, width: Int, height: Int, outRect: CGRect)? {
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
        let outRect = CGRect(x: 0, y: 0, width: detW, height: detH)
        return (scaled, detW, detH, outRect)
    }

    /// iOS 17+: runs `VNGenerateForegroundInstanceMaskRequest` and returns an inverted binary
    /// mask (foreground = black, background = white) so the downstream contour request can
    /// trace each detected subject. Returns nil when the request fails or finds no instances.
    @available(iOS 17.0, *)
    private static func makeForegroundMaskDetectionCGImage(
        from cgImage: CGImage,
        tuning: FlattenShapeDetectionTuning
    ) -> CGImage? {
        guard let prep = scaledDetectionCIImage(from: cgImage, tuning: tuning) else { return nil }
        guard let scaledCG = ciContext.createCGImage(prep.ciImage, from: prep.outRect) else { return nil }

        let maskRequest = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: scaledCG, options: [:])
        do {
            try handler.perform([maskRequest])
        } catch {
            return nil
        }

        guard let observation = maskRequest.results?.first,
              !observation.allInstances.isEmpty
        else { return nil }

        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } catch {
            return nil
        }

        // Mask is white = foreground; invert so the contour request (dark-on-light) sees subjects as dark.
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
        let inverted = maskCI.applyingFilter("CIColorInvert", parameters: [:])
        // Hard-binarize so contour tracing follows the mask boundary exactly.
        let binary = inverted.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 4.0
            ]
        )

        let maskW = CVPixelBufferGetWidth(maskBuffer)
        let maskH = CVPixelBufferGetHeight(maskBuffer)
        let renderRect = CGRect(x: 0, y: 0, width: maskW, height: maskH)
        return ciContext.createCGImage(binary, from: renderRect)
    }

    /// Fallback for iOS < 17 or when the ML request fails: original grayscale + contrast + median pipeline.
    private static func makeGrayscaleDetectionCGImage(
        from cgImage: CGImage,
        tuning: FlattenShapeDetectionTuning
    ) -> CGImage? {
        guard let prep = scaledDetectionCIImage(from: cgImage, tuning: tuning) else { return nil }

        let mono = prep.ciImage.applyingFilter("CIPhotoEffectMono", parameters: [:])
        let contrast = mono.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1 + tuning.analysisContrastBoost
            ]
        )
        let blurred = contrast.applyingFilter("CIMedianFilter", parameters: [:])

        return ciContext.createCGImage(blurred, from: prep.outRect)
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

    /// Top-level Vision contours only — skips nested `childContours` (grip ribs, inner holes, etc.).
    private static func topLevelContours(from observation: VNContoursObservation) -> [VNContour] {
        observation.topLevelContours
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

        // Vision pixel coords (origin bottom-left) → detection bitmap coords (origin top-left)
        // → warped top-left pixels.
        var warpedPoints: [CGPoint] = []
        // var detectionPoints: [CGPoint] = []  // TESTING: only needed for centerline path
        warpedPoints.reserveCapacity(rawVisionPoints.count)
        // detectionPoints.reserveCapacity(rawVisionPoints.count)
        for n in rawVisionPoints {
            let p = VNImagePointForNormalizedPoint(n, detW, detH)
            let detX = p.x
            let detY = CGFloat(detH) - p.y
            // detectionPoints.append(CGPoint(x: detX, y: detY))
            warpedPoints.append(CGPoint(x: detX * scaleToWarped, y: detY * scaleToWarped))
        }

        let loop = closedPointLoop(warpedPoints)
        guard loop.count >= 3 else { return nil }
        // let detectionLoop = closedPointLoop(detectionPoints)

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

        // TESTING: outer contour only — centerline / Zhang–Suen skeleton path disabled for perf.
        // Try centerline classification. Falls back to outer contour if topology is closed,
        // ambiguous, or has too few pixels to analyze meaningfully.
        // let centerline = centerlineMeasurement(
        //     detectionLoop: detectionLoop,
        //     detectionWidth: detW,
        //     detectionHeight: detH,
        //     scaleToWarped: scaleToWarped
        // )
        //
        // let perimeterPx: CGFloat
        // let lengthKind: ShapeLengthKind
        // if let cl = centerline {
        //     perimeterPx = cl.warpedLength
        //     lengthKind = cl.kind
        // } else {
        //     perimeterPx = outerContourPx
        //     lengthKind = .outerContour
        // }
        let perimeterPx = outerContourPx
        let lengthKind: ShapeLengthKind = .outerContour

        return ShapeCandidate(
            boundingRectImage: clippedRect,
            perimeterPixels: perimeterPx,
            lengthKind: lengthKind
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
    // private static func simplifyClosedPolygon(_ ring: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
    //     guard ring.count > 2 else { return ring }
    //     var open = ring
    //     if let f = open.first, let l = open.last, hypot(l.x - f.x, l.y - f.y) < 1e-3 {
    //         open.removeLast()
    //     }
    //     guard open.count > 2 else { return ring }
    //     let simplifiedOpen = rdp(open, epsilon: epsilon)
    //     return simplifiedOpen
    // }

    // private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
    //     guard points.count > 2 else { return points }
    //     var first = 0
    //     var last = points.count - 1
    //     var indices = Set<Int>([first, last])
    //     var stack: [(Int, Int)] = [(first, last)]

    //     while let range = stack.popLast() {
    //         first = range.0
    //         last = range.1
    //         var maxDist: CGFloat = 0
    //         var index = 0
    //         let a = points[first]
    //         let b = points[last]
    //         for i in (first + 1)..<last {
    //             let d = perpendicularDistance(points[i], lineStart: a, lineEnd: b)
    //             if d > maxDist {
    //                 index = i
    //                 maxDist = d
    //             }
    //         }
    //         if maxDist > epsilon {
    //             indices.insert(index)
    //             stack.append((first, index))
    //             stack.append((index, last))
    //         }
    //     }

    //     return points.indices.filter { indices.contains($0) }.map { points[$0] }
    // }

    // private static func perpendicularDistance(_ p: CGPoint, lineStart a: CGPoint, lineEnd b: CGPoint) -> CGFloat {
    //     let dx = b.x - a.x
    //     let dy = b.y - a.y
    //     let lenSq = dx * dx + dy * dy
    //     if lenSq < 1e-18 { return hypot(p.x - a.x, p.y - a.y) }
    //     let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
    //     let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    //     return hypot(p.x - proj.x, p.y - proj.y)
    // }

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

    // MARK: - Centerline / skeleton topology

    /// Result of attempting centerline classification on a contour's filled interior.
    private struct CenterlineMeasurement {
        let warpedLength: CGFloat
        let kind: ShapeLengthKind
    }

    /// Rasterizes the contour polygon (in detection-space coordinates), thins it with
    /// Zhang–Suen, and returns a centerline length scaled to warped pixels along with the
    /// length kind. Returns `nil` when the shape is closed, too small, or otherwise
    /// ambiguous — callers should fall back to outer contour perimeter in that case.
    private static func centerlineMeasurement(
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
