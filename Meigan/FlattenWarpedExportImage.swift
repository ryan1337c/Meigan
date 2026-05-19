//
//  FlattenWarpedExportImage.swift
//  Meigan
//
//  Renders contour bounding boxes and dimension labels into the warped bitmap for Save / Share.
//  SwiftUI overlays in `FlattenWarpResultInspectOverlay` are not part of `flattenScanResultImage`.
//

import UIKit

enum FlattenWarpedExportImage {
    /// Composites `findings` onto `base` in warped pixel space (top-left origin, same as analysis).
    static func imageWithOverlays(
        base: UIImage,
        findings: [FlattenShapeFinding],
        unit: MeasurementUnit,
        highlightedFindingId: UUID? = nil
    ) -> UIImage {
        guard let cgImage = base.cgImage else { return base }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return base }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)

        return renderer.image { ctx in
            base.draw(in: CGRect(origin: .zero, size: pixelSize))
            guard !findings.isEmpty else { return }

            let cg = ctx.cgContext
            let bounds = CGRect(origin: .zero, size: pixelSize)
            let strokeOuter = max(2, min(pixelSize.width, pixelSize.height) * 0.004)
            let strokeInner = max(1.5, strokeOuter * 0.55)
            let fontSize = max(11, min(pixelSize.width, pixelSize.height) * 0.022)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let pad: CGFloat = max(4, fontSize * 0.45)

            for finding in findings {
                let rect = finding.boundingRectImage.intersection(bounds)
                guard rect.width >= 2, rect.height >= 2 else { continue }

                let isHighlighted = finding.id == highlightedFindingId
                let innerColor = isHighlighted ? UIColor.systemYellow : UIColor.cyan

                cg.setLineWidth(strokeOuter)
                cg.setStrokeColor(UIColor.black.withAlphaComponent(0.85).cgColor)
                cg.stroke(rect)

                cg.setLineWidth(strokeInner)
                cg.setStrokeColor(innerColor.cgColor)
                cg.stroke(rect)

                let lines: [String]
                if isHighlighted {
                    let w = MeasurementUnit.formatFlattenDistance(meters: finding.widthMeters, unit: unit)
                    let h = MeasurementUnit.formatFlattenDistance(meters: finding.heightMeters, unit: unit)
                    let p = MeasurementUnit.formatFlattenDistance(meters: finding.perimeterMeters, unit: unit)
                    lines = ["W: \(w)", "H: \(h)", "P: \(p)"]
                } else {
                    let w = MeasurementUnit.formatFlattenDistance(meters: finding.widthMeters, unit: unit)
                    let h = MeasurementUnit.formatFlattenDistance(meters: finding.heightMeters, unit: unit)
                    lines = ["\(w) × \(h)"]
                }

                drawLabel(lines: lines, near: rect, in: bounds, font: font, padding: pad, context: cg)
            }
        }
    }

    private static func drawLabel(
        lines: [String],
        near rect: CGRect,
        in bounds: CGRect,
        font: UIFont,
        padding: CGFloat,
        context: CGContext
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]

        let lineHeight = font.lineHeight
        let lineSpacing: CGFloat = 2
        let textHeight = lineHeight * CGFloat(lines.count) + lineSpacing * CGFloat(max(0, lines.count - 1))
        var maxLineWidth: CGFloat = 0
        for line in lines {
            maxLineWidth = max(maxLineWidth, (line as NSString).size(withAttributes: attrs).width)
        }

        let labelW = maxLineWidth + padding * 2
        let labelH = textHeight + padding * 2
        var labelOrigin = CGPoint(x: rect.midX - labelW * 0.5, y: rect.minY - labelH - 4)
        if labelOrigin.y < bounds.minY + 2 {
            labelOrigin.y = rect.maxY + 4
        }
        labelOrigin.x = min(max(labelOrigin.x, bounds.minX + 2), bounds.maxX - labelW - 2)
        labelOrigin.y = min(max(labelOrigin.y, bounds.minY + 2), bounds.maxY - labelH - 2)

        let labelRect = CGRect(origin: labelOrigin, size: CGSize(width: labelW, height: labelH))
        let bgPath = UIBezierPath(roundedRect: labelRect, cornerRadius: min(8, labelH * 0.25))
        context.saveGState()
        context.addPath(bgPath.cgPath)
        context.setFillColor(UIColor.black.withAlphaComponent(0.72).cgColor)
        context.fillPath()

        var y = labelRect.minY + padding
        for line in lines {
            let lineSize = (line as NSString).size(withAttributes: attrs)
            let x = labelRect.midX - lineSize.width * 0.5
            (line as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            y += lineHeight + lineSpacing
        }
        context.restoreGState()
    }
}
