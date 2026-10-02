//
//  FlattenWarpedExportImage.swift
//  Meigan
//
//  Renders contours, measurement chords, and the legend card into the warped bitmap for Save / Share.
//  SwiftUI overlays in `FlattenWarpResultInspectOverlay` are not part of `flattenScanResultImage`.
//

import UIKit

enum FlattenWarpedExportImage {

    // MARK: - Types

    /// Values are in screen points and match `FlattenWarpResultInspectOverlay`; they are
    /// multiplied by ``pointScale(for:)`` so saved images look like what was on screen.
    private enum Style {
        static let contourOutlineExtraWidth: CGFloat = 2
        static let contourLineWidth: CGFloat = 2
        static let highlightedContourLineWidth: CGFloat = 3.5
        static let contourColor = UIColor.white
        static let contourOutlineColor = UIColor.black.withAlphaComponent(0.8)

        static let chordLineWidth: CGFloat = 2.5
        static let chordDash: [CGFloat] = [8, 6]
        static let extensionLineWidth: CGFloat = 1
        static let extensionLineAlpha: CGFloat = 0.6
        static let widthColor = UIColor.systemBlue
        static let heightColor = UIColor.systemOrange
        static let perimeterColor = UIColor.white

        static let legendMinWidth: CGFloat = 200
        static let legendHorizontalPadding: CGFloat = 16
        static let legendVerticalPadding: CGFloat = 14
        static let legendTitleSpacing: CGFloat = 10
        static let legendRowSpacing: CGFloat = 6
        static let legendColumnSpacing: CGFloat = 10
        static let legendValueMinSpacing: CGFloat = 8
        static let legendCornerRadius: CGFloat = 16
        static let legendBorderWidth: CGFloat = 1
        static let legendTitleFontSize: CGFloat = 12
        static let legendRowFontSize: CGFloat = 15
        static let legendFillColor = UIColor.black.withAlphaComponent(0.72)
        static let legendBorderColor = UIColor.white.withAlphaComponent(0.3)
        static let legendShadowColor = UIColor.black.withAlphaComponent(0.45)
        static let legendShadowBlur: CGFloat = 18
        static let legendShadowOffsetY: CGFloat = 10
        /// Distance from the image edge.
        static let legendMargin: CGFloat = 14
        /// Distance from the selected contour's bounds.
        static let legendGap: CGFloat = 10
        static let primaryTextColor = UIColor.white
        static let secondaryTextColor = UIColor.white.withAlphaComponent(0.6)
        static let swatchSize = CGSize(width: 24, height: 2)
        static let swatchDash: [CGFloat] = [5, 3]
        static let rotationGlyphSize: CGFloat = 13
        static let rotationSymbolName = "angle"

        static let compactLabelFontSize: CGFloat = 11
        static let compactLabelFillColor = UIColor.black.withAlphaComponent(0.72)
        static let compactLabelGap: CGFloat = 4
        static let compactLabelEdgeInset: CGFloat = 2
    }

    private struct LegendRow {
        enum Swatch {
            case line(UIColor, isDashed: Bool)
            case rotationGlyph
        }

        let label: String
        let value: String
        let swatch: Swatch
    }

    private struct LegendFonts {
        let title: UIFont
        let row: UIFont

        init(scale: CGFloat) {
            title = .systemFont(ofSize: Style.legendTitleFontSize * scale, weight: .semibold)
            row = .monospacedDigitSystemFont(ofSize: Style.legendRowFontSize * scale, weight: .medium)
        }
    }

    // MARK: - Rendering

    /// Composites `findings` onto `base` in warped pixel space (top-left origin, same as analysis).
    /// The highlighted finding gets its chords and a legend card; the rest get a compact `W × H` label.
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
            let bounds = CGRect(origin: .zero, size: pixelSize)
            base.draw(in: bounds)
            guard !findings.isEmpty else { return }

            let cg = ctx.cgContext
            let scale = pointScale(for: pixelSize)
            let highlighted = findings.first { $0.id == highlightedFindingId }

            for finding in findings where finding.id != highlighted?.id {
                drawContour(finding.contourImage, lineWidth: Style.contourLineWidth * scale, scale: scale, in: cg)
                drawCompactLabel(for: finding, unit: unit, in: bounds, scale: scale, context: cg)
            }

            if let highlighted {
                drawSelection(
                    of: highlighted,
                    otherFindings: findings.filter { $0.id != highlighted.id },
                    unit: unit,
                    in: bounds,
                    scale: scale,
                    context: cg
                )
            }
        }
    }

    /// Image pixels per screen point, from the same short-side fraction as the old stroke widths.
    private static func pointScale(for pixelSize: CGSize) -> CGFloat {
        max(1, min(pixelSize.width, pixelSize.height) * 0.004 / 2)
    }

    // MARK: - Contours

    /// Black outline under a white stroke so the contour reads on both light and dark surfaces.
    private static func drawContour(_ points: [CGPoint], lineWidth: CGFloat, scale: CGFloat, in context: CGContext) {
        guard points.count >= 2 else { return }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()

        context.saveGState()
        context.setLineJoin(.round)
        for (color, width) in [
            (Style.contourOutlineColor, lineWidth + Style.contourOutlineExtraWidth * scale),
            (Style.contourColor, lineWidth)
        ] {
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: - Selection

    /// The legend card is an obstacle for exterior lines, and its Rotation row depends on
    /// those lines, so lay out once with three rows and again with four if the row is needed.
    private static func drawSelection(
        of finding: FlattenShapeFinding,
        otherFindings: [FlattenShapeFinding],
        unit: MeasurementUnit,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        let fonts = LegendFonts(scale: scale)
        let metrics = FlattenDimensionLayout.Metrics.screen.scaled(by: scale)

        func layout(showsRotation: Bool) -> (rows: [LegendRow], legendRect: CGRect, width: FlattenDimensionPlacement, height: FlattenDimensionPlacement) {
            let rows = legendRows(for: finding, unit: unit, showsRotation: showsRotation)
            let legendRect = Self.legendRect(
                size: legendSize(for: rows, fonts: fonts, scale: scale),
                anchor: finding.boundingRectImage,
                in: bounds,
                scale: scale
            )
            let obstacles = FlattenDimensionLayout.Obstacles(findings: otherFindings, rects: [legendRect])
            func placement(for axis: FlattenDimensionLayout.Axis) -> FlattenDimensionPlacement {
                FlattenDimensionLayout.layout(
                    for: axis,
                    of: finding,
                    imageToView: .identity,
                    viewBounds: bounds,
                    obstacles: obstacles,
                    metrics: metrics
                )
            }
            return (rows, legendRect, placement(for: .width), placement(for: .height))
        }

        let threeRowLayout = layout(showsRotation: false)
        let needsRotation = FlattenDimensionLayout.shouldShowRotation(
            for: finding,
            placements: [threeRowLayout.width, threeRowLayout.height]
        )
        let selection = needsRotation ? layout(showsRotation: true) : threeRowLayout

        drawContour(finding.contourImage, lineWidth: Style.highlightedContourLineWidth * scale, scale: scale, in: context)
        drawDimension(selection.width, color: Style.widthColor, arrowheadLength: metrics.arrowheadLength, scale: scale, in: context)
        drawDimension(selection.height, color: Style.heightColor, arrowheadLength: metrics.arrowheadLength, scale: scale, in: context)
        drawLegend(selection.rows, in: selection.legendRect, fonts: fonts, scale: scale, context: context)
    }

    // MARK: - Dimension Lines

    /// Exterior placements add thin extension lines in the same color, so it stays clear which
    /// points were measured.
    private static func drawDimension(
        _ placement: FlattenDimensionPlacement,
        color: UIColor,
        arrowheadLength: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        switch placement {
        case .interior(let chord):
            drawMeasureChord(chord, color: color, arrowheadLength: arrowheadLength, scale: scale, in: context)
        case .exterior(let dimensionLine, let extensionA, let extensionB):
            context.saveGState()
            context.setStrokeColor(color.withAlphaComponent(Style.extensionLineAlpha).cgColor)
            context.setLineWidth(Style.extensionLineWidth * scale)
            for line in [extensionA, extensionB] {
                context.move(to: line.start)
                context.addLine(to: line.end)
            }
            context.strokePath()
            context.restoreGState()
            drawMeasureChord(dimensionLine, color: color, arrowheadLength: arrowheadLength, scale: scale, in: context)
        }
    }

    /// Dashed line with filled arrowheads touching both ends. The shaft is inset by the
    /// arrowhead length so dashes never poke past the tips.
    private static func drawMeasureChord(
        _ segment: FlattenMeasureSegment,
        color: UIColor,
        arrowheadLength: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let length = segment.length
        guard length > 0 else { return }

        let direction = CGVector(dx: (segment.end.x - segment.start.x) / length, dy: (segment.end.y - segment.start.y) / length)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let headLength = min(arrowheadLength, length / 3)
        let headHalfWidth = headLength * 0.5

        func offset(_ point: CGPoint, along axis: CGVector, by distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + axis.dx * distance, y: point.y + axis.dy * distance)
        }

        let shaftStart = offset(segment.start, along: direction, by: headLength)
        let shaftEnd = offset(segment.end, along: direction, by: -headLength)

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(Style.chordLineWidth * scale)
        context.setLineDash(phase: 0, lengths: Style.chordDash.map { $0 * scale })
        context.move(to: shaftStart)
        context.addLine(to: shaftEnd)
        context.strokePath()

        context.setFillColor(color.cgColor)
        for (tip, base) in [(segment.start, shaftStart), (segment.end, shaftEnd)] {
            context.move(to: tip)
            context.addLine(to: offset(base, along: normal, by: headHalfWidth))
            context.addLine(to: offset(base, along: normal, by: -headHalfWidth))
            context.closePath()
        }
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Legend

    private static func legendRows(for finding: FlattenShapeFinding, unit: MeasurementUnit, showsRotation: Bool) -> [LegendRow] {
        func format(_ meters: Float) -> String {
            MeasurementUnit.formatFlattenDistance(meters: meters, unit: unit)
        }

        var rows = [
            LegendRow(label: "Width", value: format(finding.widthMeters), swatch: .line(Style.widthColor, isDashed: true)),
            LegendRow(label: "Height", value: format(finding.heightMeters), swatch: .line(Style.heightColor, isDashed: true)),
            LegendRow(label: "Perimeter", value: format(finding.perimeterMeters), swatch: .line(Style.perimeterColor, isDashed: false))
        ]
        if showsRotation {
            let degrees = Double(FlattenDimensionLayout.rotationDegrees(of: finding))
            rows.append(LegendRow(
                label: "Rotation",
                value: "\(degrees.formatted(.number.precision(.fractionLength(0))))°",
                swatch: .rotationGlyph
            ))
        }
        return rows
    }

    private static let legendTitle = "Selected region"

    private static func legendSize(for rows: [LegendRow], fonts: LegendFonts, scale: CGFloat) -> CGSize {
        let rowAttributes: [NSAttributedString.Key: Any] = [.font: fonts.row]
        let labelWidth = rows.map { ($0.label as NSString).size(withAttributes: rowAttributes).width }.max() ?? 0
        let valueWidth = rows.map { ($0.value as NSString).size(withAttributes: rowAttributes).width }.max() ?? 0
        let titleWidth = (legendTitle as NSString).size(withAttributes: [.font: fonts.title]).width
        let rowWidth = (Style.swatchSize.width + Style.legendColumnSpacing + Style.legendValueMinSpacing) * scale
            + labelWidth + valueWidth
        let contentWidth = max(rowWidth, titleWidth)

        let rowCount = CGFloat(rows.count)
        let contentHeight = fonts.title.lineHeight
            + Style.legendTitleSpacing * scale
            + fonts.row.lineHeight * rowCount
            + Style.legendRowSpacing * scale * max(0, rowCount - 1)

        return CGSize(
            width: max(contentWidth + Style.legendHorizontalPadding * 2 * scale, Style.legendMinWidth * scale),
            height: contentHeight + Style.legendVerticalPadding * 2 * scale
        )
    }

    /// Above the anchor when there is room, otherwise below; clamped inside the image.
    private static func legendRect(size: CGSize, anchor: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        let margin = Style.legendMargin * scale
        let gap = Style.legendGap * scale
        let minY = bounds.minY + margin
        let maxY = max(minY, bounds.maxY - margin - size.height)
        let minX = bounds.minX + margin
        let maxX = max(minX, bounds.maxX - margin - size.width)

        let yAbove = anchor.minY - gap - size.height
        let y = yAbove >= minY ? yAbove : anchor.maxY + gap
        let x = anchor.midX - size.width / 2

        return CGRect(
            x: min(max(x, minX), maxX),
            y: min(max(y, minY), maxY),
            width: size.width,
            height: size.height
        )
    }

    private static func drawLegend(_ rows: [LegendRow], in rect: CGRect, fonts: LegendFonts, scale: CGFloat, context: CGContext) {
        let card = UIBezierPath(roundedRect: rect, cornerRadius: Style.legendCornerRadius * scale).cgPath

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: Style.legendShadowOffsetY * scale),
            blur: Style.legendShadowBlur * scale,
            color: Style.legendShadowColor.cgColor
        )
        context.addPath(card)
        context.setFillColor(Style.legendFillColor.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(card)
        context.setStrokeColor(Style.legendBorderColor.cgColor)
        context.setLineWidth(Style.legendBorderWidth * scale)
        context.strokePath()
        context.restoreGState()

        let leading = rect.minX + Style.legendHorizontalPadding * scale
        let trailing = rect.maxX - Style.legendHorizontalPadding * scale
        var y = rect.minY + Style.legendVerticalPadding * scale

        (legendTitle as NSString).draw(
            at: CGPoint(x: leading, y: y),
            withAttributes: [.font: fonts.title, .foregroundColor: Style.secondaryTextColor]
        )
        y += fonts.title.lineHeight + Style.legendTitleSpacing * scale

        let labelAttributes: [NSAttributedString.Key: Any] = [.font: fonts.row, .foregroundColor: Style.secondaryTextColor]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: fonts.row, .foregroundColor: Style.primaryTextColor]
        let swatchWidth = Style.swatchSize.width * scale

        for row in rows {
            let swatchRect = CGRect(x: leading, y: y, width: swatchWidth, height: fonts.row.lineHeight)
            drawSwatch(row.swatch, in: swatchRect, scale: scale, context: context)

            (row.label as NSString).draw(
                at: CGPoint(x: swatchRect.maxX + Style.legendColumnSpacing * scale, y: y),
                withAttributes: labelAttributes
            )
            let value = row.value as NSString
            let valueWidth = value.size(withAttributes: valueAttributes).width
            value.draw(at: CGPoint(x: trailing - valueWidth, y: y), withAttributes: valueAttributes)

            y += fonts.row.lineHeight + Style.legendRowSpacing * scale
        }
    }

    /// Swatches match the on-image line styles.
    private static func drawSwatch(_ swatch: LegendRow.Swatch, in rect: CGRect, scale: CGFloat, context: CGContext) {
        switch swatch {
        case .line(let color, let isDashed):
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(Style.swatchSize.height * scale)
            if isDashed {
                context.setLineDash(phase: 0, lengths: Style.swatchDash.map { $0 * scale })
            }
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            context.restoreGState()
        case .rotationGlyph:
            let configuration = UIImage.SymbolConfiguration(pointSize: Style.rotationGlyphSize * scale, weight: .semibold)
            guard let glyph = UIImage(systemName: Style.rotationSymbolName, withConfiguration: configuration)?
                .withTintColor(Style.primaryTextColor, renderingMode: .alwaysOriginal)
            else { return }
            glyph.draw(at: CGPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2))
        }
    }

    // MARK: - Compact Labels

    private static func drawCompactLabel(
        for finding: FlattenShapeFinding,
        unit: MeasurementUnit,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        let anchor = finding.boundingRectImage.intersection(bounds)
        guard anchor.width >= 2, anchor.height >= 2 else { return }

        let width = MeasurementUnit.formatFlattenDistance(meters: finding.widthMeters, unit: unit)
        let height = MeasurementUnit.formatFlattenDistance(meters: finding.heightMeters, unit: unit)
        let text = "\(width) × \(height)" as NSString

        let font = UIFont.systemFont(ofSize: Style.compactLabelFontSize * scale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Style.primaryTextColor]
        let padding = max(4, font.pointSize * 0.45)
        let gap = Style.compactLabelGap * scale
        let inset = Style.compactLabelEdgeInset * scale

        let textSize = text.size(withAttributes: attributes)
        let labelWidth = textSize.width + padding * 2
        let labelHeight = font.lineHeight + padding * 2
        var origin = CGPoint(x: anchor.midX - labelWidth * 0.5, y: anchor.minY - labelHeight - gap)
        if origin.y < bounds.minY + inset {
            origin.y = anchor.maxY + gap
        }
        origin.x = min(max(origin.x, bounds.minX + inset), bounds.maxX - labelWidth - inset)
        origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - labelHeight - inset)

        let labelRect = CGRect(origin: origin, size: CGSize(width: labelWidth, height: labelHeight))
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: labelRect, cornerRadius: min(8 * scale, labelHeight * 0.25)).cgPath)
        context.setFillColor(Style.compactLabelFillColor.cgColor)
        context.fillPath()
        context.restoreGState()

        text.draw(at: CGPoint(x: labelRect.midX - textSize.width * 0.5, y: labelRect.minY + padding), withAttributes: attributes)
    }
}
