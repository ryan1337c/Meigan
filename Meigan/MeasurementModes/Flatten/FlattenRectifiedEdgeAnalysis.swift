//
//  FlattenRectifiedEdgeAnalysis.swift
//  Meigan
//
//  Detection-only pipeline. On iOS 17+, runs `VNGenerateForegroundInstanceMaskRequest`
//  at full resolution to obtain one soft subject mask per instance. On earlier systems
//  (or if the ML request fails), falls back to a grayscale + contrast + median
//  preprocessing pass. The original `UIImage` used for display is never modified.
//
//  Split across:
//  - this file: public types, entry points, and detection-bitmap preparation
//  - `FlattenRectifiedEdgeAnalysis+ForegroundMask.swift`: full-res per-instance soft masks
//  - `FlattenRectifiedEdgeAnalysis+MaskContour.swift`: marching-squares contour per soft mask
//  - `FlattenRectifiedEdgeAnalysis+Dimensions.swift`: oriented width / height chords per contour
//  - `FlattenRectifiedEdgeAnalysis+Contours.swift`: Vision contour fallback → candidate → finding
//  - `FlattenRectifiedEdgeAnalysis+Skeleton.swift`: centerline / skeleton topology (currently unused)
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

/// A straight measurement line in warped pixel space (origin top-left).
struct FlattenMeasureSegment: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint

    var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}

/// One closed region discovered on the rectified (warped) bitmap, with geometry expressed
/// in the warped image’s pixel space (origin top-left, matching SwiftUI `Image` layout).
struct FlattenShapeFinding: Equatable, Sendable, Identifiable {
    let id: UUID
    /// Closed outer contour polygon in warped pixels.
    let contourImage: [CGPoint]
    /// Axis-aligned bounds of `contourImage`, intersected with `0…width × 0…height` of the warped image.
    /// Used for sorting, popup placement, and fast hit-test culling.
    let boundingRectImage: CGRect
    /// Derived from `boundingRectImage` for overlay layout (optional convenience).
    let boundingRectNormalized: CGRect
    /// Chord measured for `widthMeters`, along the object axis closer to image-horizontal.
    let widthSegment: FlattenMeasureSegment
    /// Chord measured for `heightMeters`, perpendicular to `widthSegment`'s axis.
    let heightSegment: FlattenMeasureSegment
    /// Rotation of the width axis from image-horizontal, in radians.
    let orientationRadians: CGFloat
    /// `widthSegment` length in meters.
    let widthMeters: Float
    /// `heightSegment` length in meters.
    let heightMeters: Float
    /// Outer contour perimeter for closed shapes, or centerline path length for open/branching
    /// strokes. See `lengthKind` for which measurement produced this value.
    let perimeterMeters: Float
    /// Indicates whether `perimeterMeters` is an outer contour perimeter or a centerline length.
    let lengthKind: ShapeLengthKind
}

/// Thresholds and caps for the Vision + Core Image contour pipeline (`FlattenRectifiedEdgeAnalysis`).
struct FlattenShapeDetectionTuning: Equatable, Sendable {
    /// Longest edge of the fallback bitmap passed into Vision (smaller = faster; coordinates map back to full warped size).
    var detectionMaxLongestEdge: CGFloat
    /// Extra contrast applied to the grayscale analysis image before Vision contour detection.
    var analysisContrastBoost: Float
    /// `VNDetectContoursRequest.contrastAdjustment` — higher can pull fainter strokes at the cost of noise.
    var visionContrastAdjustment: Float
    /// Minimum clipped bounding-box area (px²) in warped space to keep a raw contour fragment.
    var minimumClippedBoundingBoxAreaPixels: CGFloat
    /// Minimum object area as a fraction of the warped image area.
    var minimumObjectAreaFraction: CGFloat
    /// Reject contours whose clipped bbox covers at least this fraction of the warped image area.
    /// `VNDetectContoursRequest` typically emits one huge contour around the whole frame; this drops it.
    /// Range `(0, 1]`; `1` disables the upper bound.
    var maxBoundingBoxAreaFraction: CGFloat
    /// After filtering, keep at most this many shapes by descending clipped bbox area (`0` = unlimited).
    var maxReturnedShapes: Int
    /// Run a second subject-mask pass on four overlapping crops to add objects the full-image
    /// pass skipped. Costs four more Vision requests per scan.
    var isTiledDetectionEnabled: Bool

    static let `default` = FlattenShapeDetectionTuning(
        detectionMaxLongestEdge: 960,
        analysisContrastBoost: 0.35,
        visionContrastAdjustment: 1.2,
        minimumClippedBoundingBoxAreaPixels: 200,
        minimumObjectAreaFraction: 0.008,
        maxBoundingBoxAreaFraction: 0.88,
        maxReturnedShapes: 32,
        isTiledDetectionEnabled: true
    )
}

/// Contour detection output plus the bitmap fed to Vision (for tuning / debug).
struct FlattenShapeDetectionResult: Sendable {
    let findings: [FlattenShapeFinding]
    /// On iOS 17+, the union of Vision subject masks (black on white); otherwise the
    /// mono+contrast+median fallback bitmap. Never shown in the main UI.
    let detectionPreviewImage: UIImage?
}

/// Contour-driven shape discovery on the birds-eye `UIImage` from `inverseWarpQuadImage`.
enum FlattenRectifiedEdgeAnalysis {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Intermediate per-contour result before filtering and unit conversion.
    struct ShapeCandidate {
        /// Closed outer contour polygon in warped pixels.
        var contourImage: [CGPoint]
        var boundingRectImage: CGRect
        var widthSegment: FlattenMeasureSegment
        var heightSegment: FlattenMeasureSegment
        var orientationRadians: CGFloat
        var perimeterPixels: CGFloat
        var lengthKind: ShapeLengthKind
    }

    // MARK: - Public

    /// Runs subject-mask detection (or the grayscale contour fallback); returns shapes in **warped** pixel coordinates.
    ///
    /// - Parameters:
    ///   - warpedImage: Full-color rectified bitmap shown in the UI (read-only).
    ///   - pixelsPerMeter: From `FlattenMeasurementMode.FlattenScanAnalysis.pixelsPerMeter`.
    ///   - tuning: Contour / edge thresholds and max shape count; use ``FlattenShapeDetectionTuning/default`` unless experimenting.
    /// - Note: `perimeterMeters` skips contour stretches along or outside the image frame, so values track visible ink when a stroke touches the frame edge.
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

        let candidates: [ShapeCandidate]
        let detectionPreviewImage: UIImage?
        if #available(iOS 17.0, *),
           let visionMasks = makeForegroundInstanceMasks(from: cgImage, includeTiles: tuning.isTiledDetectionEnabled) {
            candidates = visionMasks.compactMap {
                makeCandidate(from: $0, imageBounds: imageBounds, tuning: tuning)
            }
            detectionPreviewImage = detectionPreview(
                of: visionMasks,
                imageWidth: cgImage.width,
                imageHeight: cgImage.height
            ).map { UIImage(cgImage: $0) }
        } else if let gray = makeGrayscaleDetectionCGImage(from: cgImage, tuning: tuning) {
            candidates = contourRequestCandidates(on: gray, imageBounds: imageBounds, tuning: tuning)
            detectionPreviewImage = UIImage(cgImage: gray)
        } else {
            return FlattenShapeDetectionResult(findings: [], detectionPreviewImage: nil)
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

    // MARK: - Fallback contours

    /// Fallback candidates from `VNDetectContoursRequest` on the downscaled grayscale bitmap,
    /// one per top-level contour.
    private static func contourRequestCandidates(
        on detection: CGImage,
        imageBounds: CGRect,
        tuning: FlattenShapeDetectionTuning
    ) -> [ShapeCandidate] {
        guard let observation = runContourRequest(on: detection, tuning: tuning) else { return [] }

        let detectionWidth = CGFloat(detection.width)
        let detectionHeight = CGFloat(detection.height)
        return topLevelContours(from: observation).compactMap { contour in
            makeCandidate(
                from: contour,
                detectionWidth: detectionWidth,
                detectionHeight: detectionHeight,
                scaleToWarped: imageBounds.width / detectionWidth,
                imageBounds: imageBounds,
                tuning: tuning
            )
        }
    }

    // MARK: - Detection image (never shown)

    /// Computes the scaled detection extent and a downscaled CIImage for the fallback path.
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
}
