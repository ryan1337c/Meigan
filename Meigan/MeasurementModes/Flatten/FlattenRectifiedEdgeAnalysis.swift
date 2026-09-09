//
//  FlattenRectifiedEdgeAnalysis.swift
//  Meigan
//
//  Detection-only pipeline. On iOS 17+, runs `VNGenerateForegroundInstanceMaskRequest`
//  to obtain a clean binary subject mask, then traces contours on that mask. On earlier
//  systems (or if the ML request fails), falls back to a grayscale + contrast + median
//  preprocessing pass. The original `UIImage` used for display is never modified.
//
//  Split across:
//  - this file: public types, entry points, and detection-bitmap preparation
//  - `FlattenRectifiedEdgeAnalysis+Contours.swift`: Vision contour → candidate → finding
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

    /// Intermediate per-contour result before merging and unit conversion.
    struct ShapeCandidate {
        var boundingRectImage: CGRect
        var perimeterPixels: CGFloat
        var lengthKind: ShapeLengthKind
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
}
