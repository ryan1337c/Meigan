//
//  FlattenMeasurementMode+ScanImage.swift
//  Meigan
//
//  Snapshot cropping, world → image-plane projection, and the Core Image perspective
//  correction that produces the rectified output bitmap.
//

import ARKit
import CoreImage
import RealityKit
import simd
import UIKit

extension FlattenMeasurementMode {
    static func croppedScanImage(
        from image: UIImage,
        around points: [SIMD3<Float>],
        in arView: ARView
    ) -> UIImage {
        guard let cgImage = image.cgImage, !points.isEmpty else { return image }

        let projected = points.compactMap { arView.project($0) }
        guard projected.count == points.count else { return image }

        let xs = projected.map(\.x)
        let ys = projected.map(\.y)
        let padding: CGFloat = 28
        let viewBounds = arView.bounds
        let minX = max((xs.min() ?? 0) - padding, viewBounds.minX)
        let maxX = min((xs.max() ?? viewBounds.maxX) + padding, viewBounds.maxX)
        let minY = max((ys.min() ?? 0) - padding, viewBounds.minY)
        let maxY = min((ys.max() ?? viewBounds.maxY) + padding, viewBounds.maxY)

        guard maxX > minX, maxY > minY, viewBounds.width > 0, viewBounds.height > 0 else {
            return image
        }

        let scaleX = CGFloat(cgImage.width) / viewBounds.width
        let scaleY = CGFloat(cgImage.height) / viewBounds.height
        let cropRect = CGRect(
            x: minX * scaleX,
            y: minY * scaleY,
            width: (maxX - minX) * scaleX,
            height: (maxY - minY) * scaleY
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))

        guard !cropRect.isNull,
              cropRect.width > 1,
              cropRect.height > 1,
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return image
        }

        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    static func projectToImagePlane(
        _ points: [SIMD3<Float>],
        frame: ARFrame,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) -> [SIMD2<Float>] {
        guard !points.isEmpty,
              viewportSize.width > 0,
              viewportSize.height > 0
        else {
            return []
        }

        return points.compactMap { point in
            let projected = frame.camera.projectPoint(point, orientation: orientation, viewportSize: viewportSize)
            guard projected.x.isFinite, projected.y.isFinite else { return nil }
            return SIMD2<Float>(Float(projected.x), Float(projected.y))
        }
    }

    static func interfaceOrientation(in arView: ARView) -> UIInterfaceOrientation {
        if let orientation = arView.window?.windowScene?.interfaceOrientation {
            return orientation
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait
    }

    static func scanCanvasSize(in arView: ARView, footerHeight: CGFloat) -> CGSize {
        let width = max(1, arView.bounds.width)
        let reservedFooterHeight = max(0, footerHeight)
        let height = max(1, arView.bounds.height - reservedFooterHeight)
        return CGSize(width: width, height: height)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders the rectified quad larger than the on-screen fitted preview while keeping aspect ratio.
    private enum FlattenOutputImageConfig {
        /// Multiplier applied to the fitted canvas size (points) for export resolution.
        static let resolutionMultiplier: CGFloat = 2.5
        /// Hard cap on the longest edge in pixels to avoid huge allocations.
        static let maxLongestEdgePixels: CGFloat = 4096
    }

    static func inverseWarpQuadImage(
        from sourceImage: UIImage,
        analysis: FlattenScanAnalysis,
        viewportSize: CGSize
    ) -> UIImage? {
        guard analysis.imagePlanePoints.count == 4,
              let inputImage = CIImage(image: sourceImage),
              viewportSize.width > 0,
              viewportSize.height > 0
        else {
            return nil
        }

        let imageExtent = inputImage.extent
        let sourceWidth = imageExtent.width
        let sourceHeight = imageExtent.height
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }

        let baseWidth = analysis.fittedCanvasRect.width * FlattenOutputImageConfig.resolutionMultiplier
        let baseHeight = analysis.fittedCanvasRect.height * FlattenOutputImageConfig.resolutionMultiplier
        let longest = max(baseWidth, baseHeight)
        let clampScale: CGFloat
        if longest > FlattenOutputImageConfig.maxLongestEdgePixels, longest > 0 {
            clampScale = FlattenOutputImageConfig.maxLongestEdgePixels / longest
        } else {
            clampScale = 1
        }
        let scaledWidth = max(1, baseWidth * clampScale)
        let scaledHeight = max(1, baseHeight * clampScale)
        let targetWidth = max(1, Int(round(scaledWidth)))
        let targetHeight = max(1, Int(round(scaledHeight)))
        guard targetWidth > 1, targetHeight > 1 else { return nil }

        let scaleX = sourceWidth / viewportSize.width
        let scaleY = sourceHeight / viewportSize.height
        func imagePoint(_ point: SIMD2<Float>) -> CIVector {
            let x = CGFloat(point.x) * scaleX + imageExtent.minX
            // ARKit/UIView coordinates are top-left origin; Core Image is bottom-left.
            let y = imageExtent.maxY - CGFloat(point.y) * scaleY
            return CIVector(x: x, y: y)
        }

        guard let correction = CIFilter(name: "CIPerspectiveCorrection") else {
            return nil
        }
        correction.setValue(inputImage, forKey: kCIInputImageKey)
        correction.setValue(imagePoint(analysis.imagePlanePoints[0]), forKey: "inputTopLeft")
        correction.setValue(imagePoint(analysis.imagePlanePoints[1]), forKey: "inputTopRight")
        correction.setValue(imagePoint(analysis.imagePlanePoints[2]), forKey: "inputBottomRight")
        correction.setValue(imagePoint(analysis.imagePlanePoints[3]), forKey: "inputBottomLeft")

        guard let corrected = correction.outputImage else { return nil }
        let correctedExtent = corrected.extent.integral
        guard correctedExtent.width > 1, correctedExtent.height > 1 else { return nil }

        let normalized = corrected.transformed(
            by: CGAffineTransform(translationX: -correctedExtent.minX, y: -correctedExtent.minY)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(targetWidth) / correctedExtent.width,
                y: CGFloat(targetHeight) / correctedExtent.height
            )
        )
        let outputExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        guard let cgImage = ciContext.createCGImage(scaled, from: outputExtent) else {
            return nil
        }

        // Scale 1 so pixel dimensions match the bitmap (preview shows the full export size).
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    static func renderedPixelsPerMeter(
        for warpedImage: UIImage,
        analysis: FlattenScanAnalysis
    ) -> Float {
        guard analysis.physicalSizeMeters.x > 1e-5,
              analysis.physicalSizeMeters.y > 1e-5
        else {
            return analysis.pixelsPerMeter
        }

        let pixelSize: CGSize
        if let cgImage = warpedImage.cgImage {
            pixelSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        } else {
            pixelSize = CGSize(
                width: warpedImage.size.width * warpedImage.scale,
                height: warpedImage.size.height * warpedImage.scale
            )
        }

        let horizontal = Float(pixelSize.width) / analysis.physicalSizeMeters.x
        let vertical = Float(pixelSize.height) / analysis.physicalSizeMeters.y
        let renderedScale = min(horizontal, vertical)
        return renderedScale > 1e-5 ? renderedScale : analysis.pixelsPerMeter
    }
}
