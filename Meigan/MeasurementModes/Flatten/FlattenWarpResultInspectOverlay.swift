//
//  FlattenWarpResultInspectOverlay.swift
//  Meigan
//

import SwiftUI
import UIKit

/// Full-color warped result with SwiftUI vector contour strokes aligned to `scaledToFit` letterboxing.
/// Taps map to image pixels and select the smallest contour containing the point.
struct FlattenWarpResultInspectOverlay: View {
    // MARK: - Properties

    private enum Style {
        static let contourOutlineExtraWidth: CGFloat = 2
        static let contourLineWidth: CGFloat = 2
        static let selectedContourLineWidth: CGFloat = 3.5
        static let chordLineWidth: CGFloat = 2.5
        static let chordDash: [CGFloat] = [8, 6]
        static let arrowheadLength = FlattenDimensionLayout.Metrics.screen.arrowheadLength
        static let extensionLineWidth: CGFloat = 1
        static let extensionLineOpacity: Double = 0.6
        static let swatchSize = CGSize(width: 24, height: 2)
        static let swatchDash: [CGFloat] = [5, 3]
        static let rotationGlyphSize: CGFloat = 13
        static let widthColor = Color.blue
        static let heightColor = Color.orange
        static let perimeterColor = Color.white
        static let popupWidth: CGFloat = 260
        /// Estimated card height with the three measurement rows.
        static let popupBaseHeight: CGFloat = 132
        static let popupRowHeight: CGFloat = 26
    }

    /// Where the selected finding's dimension lines and legend card go.
    private struct SelectionLayout {
        let popupCenter: CGPoint
        let width: FlattenDimensionPlacement
        let height: FlattenDimensionPlacement
        let showsRotation: Bool
    }

    let image: UIImage
    let findings: [FlattenShapeFinding]
    let detectionPreviewImage: UIImage?
    let measurementUnit: MeasurementUnit
    let photoSavedBannerMessage: String?
    let onDismiss: () -> Void
    let onSave: (UIImage) -> Void
    let onShare: (UIImage) -> Void
    var onSaveDetectionPreview: ((UIImage, @escaping (Bool) -> Void) -> Void)?

    @State private var selectedFindingId: UUID?
    @State private var showsDetectionPreviewSheet = false

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let container = CGSize(width: geo.size.width, height: geo.size.height)
            let pixelSize = Self.warpedImagePixelSize(image)
            let imageAspect = pixelSize.width / max(pixelSize.height, 1)
            let displayed = Self.letterboxedImageRect(container: container, imageAspect: imageAspect)
            let imageToView = Self.imageToViewTransform(imagePixelSize: pixelSize, displayedInContainer: displayed)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ZStack(alignment: .topLeading) {
                    ForEach(findings.filter { $0.id != selectedFindingId }) { finding in
                        contourView(for: finding, isSelected: false, imageToView: imageToView)
                    }

                    if let selected = findings.first(where: { $0.id == selectedFindingId }) {
                        let layout = selectionLayout(
                            for: selected,
                            imageToView: imageToView,
                            displayedImageRect: displayed,
                            container: container,
                            safeInsets: geo.safeAreaInsets
                        )
                        contourView(for: selected, isSelected: true, imageToView: imageToView)
                        dimensionView(layout.width, color: Style.widthColor)
                        dimensionView(layout.height, color: Style.heightColor)

                        selectionPopup(for: selected, showsRotation: layout.showsRotation)
                            .position(x: layout.popupCenter.x, y: layout.popupCenter.y)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.92, anchor: .center).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selectedFindingId)
                            .allowsHitTesting(false)
                            .zIndex(2)
                    }

                    Color.clear
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    selectFinding(
                                        at: value.location,
                                        displayedImageRect: displayed,
                                        imagePixelSize: pixelSize
                                    )
                                }
                        )
                }
                .frame(width: geo.size.width, height: geo.size.height)

                VStack(spacing: 0) {
                    ZStack {
                        Text("Flattened Surface")
                            .font(.headline)

                        HStack {
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background {
                                        Circle()
                                            .fill(.thinMaterial)
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                                    }
                            }
                            .accessibilityLabel("Done")

                            Spacer()

                            Menu {
                                Button {
                                    onSave(exportImageForAlbum())
                                } label: {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }

                                Button {
                                    onShare(exportImageForAlbum())
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                if detectionPreviewImage != nil {
                                    Button {
                                        showsDetectionPreviewSheet = true
                                    } label: {
                                        Label("Vision Input", systemImage: "viewfinder")
                                    }
                                }

                                Divider()

                                Button(role: .destructive, action: onDismiss) {
                                    Label("Delete Screenshot", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 22, weight: .semibold))
                                    .frame(width: 48, height: 48)
                                    .background {
                                        Circle()
                                            .fill(Color.accentColor)
                                            .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 4)
                                    }
                            }
                            .accessibilityLabel("Result actions")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, geo.safeAreaInsets.top + 12)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)

                    if let photoSavedBannerMessage {
                        TopDownNoticeBanner(message: photoSavedBannerMessage)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(10)
                    }

                    Spacer()
                        .allowsHitTesting(false)
                }
                .foregroundStyle(.white)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: photoSavedBannerMessage)
            }
            .ignoresSafeArea()
            .onChange(of: findings) { _ in
                selectedFindingId = nil
            }
            .sheet(isPresented: $showsDetectionPreviewSheet) {
                if let detectionPreviewImage {
                    FlattenDetectionPreviewSheet(
                        image: detectionPreviewImage,
                        onSave: { completion in
                            guard let onSaveDetectionPreview else {
                                completion(false)
                                return
                            }
                            onSaveDetectionPreview(detectionPreviewImage, completion)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Views

    /// Black outline under a white stroke so the contour reads on both light and dark surfaces.
    private func contourView(
        for finding: FlattenShapeFinding,
        isSelected: Bool,
        imageToView: CGAffineTransform
    ) -> some View {
        let path = Self.closedPath(through: finding.contourImage).applying(imageToView)
        let lineWidth = isSelected ? Style.selectedContourLineWidth : Style.contourLineWidth
        return ZStack {
            path.stroke(
                Color.black.opacity(0.8),
                style: StrokeStyle(lineWidth: lineWidth + Style.contourOutlineExtraWidth, lineJoin: .round)
            )
            path.stroke(
                Color.white,
                style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }

    /// Exterior placements add thin extension lines in the same color, so it stays clear which
    /// points were measured.
    @ViewBuilder
    private func dimensionView(_ placement: FlattenDimensionPlacement, color: Color) -> some View {
        switch placement {
        case .interior(let chord):
            measureChord(chord, color: color)
        case .exterior(let dimensionLine, let extensionA, let extensionB):
            ZStack {
                Path { path in
                    for line in [extensionA, extensionB] {
                        path.move(to: line.start)
                        path.addLine(to: line.end)
                    }
                }
                .stroke(color.opacity(Style.extensionLineOpacity), lineWidth: Style.extensionLineWidth)
                measureChord(dimensionLine, color: color)
            }
            .allowsHitTesting(false)
        }
    }

    /// Dashed measurement line in view space, with filled arrowheads touching both ends.
    private func measureChord(_ segment: FlattenMeasureSegment, color: Color) -> some View {
        let paths = Self.chordPaths(from: segment.start, to: segment.end)
        return ZStack {
            paths.shaft.stroke(
                color,
                style: StrokeStyle(lineWidth: Style.chordLineWidth, dash: Style.chordDash)
            )
            paths.arrowheads.fill(color)
        }
        .allowsHitTesting(false)
    }

    /// Legend card next to the selected contour; swatches match the on-image line styles.
    private func selectionPopup(for finding: FlattenShapeFinding, showsRotation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected region")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                legendRow(label: "Width", value: formatLength(finding.widthMeters)) {
                    legendSwatch(color: Style.widthColor, isDashed: true)
                }
                legendRow(label: "Height", value: formatLength(finding.heightMeters)) {
                    legendSwatch(color: Style.heightColor, isDashed: true)
                }
                legendRow(label: "Perimeter", value: formatLength(finding.perimeterMeters)) {
                    legendSwatch(color: Style.perimeterColor, isDashed: false)
                }
                if showsRotation {
                    legendRow(label: "Rotation", value: formatDegrees(FlattenDimensionLayout.rotationDegrees(of: finding))) {
                        Image(systemName: "angle")
                            .font(.system(size: Style.rotationGlyphSize, weight: .semibold))
                            .frame(width: Style.swatchSize.width)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(.subheadline.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 200, maxWidth: Style.popupWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    private func legendRow<Swatch: View>(
        label: String,
        value: String,
        @ViewBuilder swatch: () -> Swatch
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            swatch()
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func legendSwatch(color: Color, isDashed: Bool) -> some View {
        let size = Style.swatchSize
        return Path { path in
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        }
        .stroke(color, style: StrokeStyle(lineWidth: size.height, dash: isDashed ? Style.swatchDash : []))
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    /// Warped bitmap plus contours/labels in image pixel space (what Save/Share must write, not `image` alone).
    private func exportImageForAlbum() -> UIImage {
        FlattenWarpedExportImage.imageWithOverlays(
            base: image,
            findings: findings,
            unit: measurementUnit,
            highlightedFindingId: selectedFindingId
        )
    }

    private func selectFinding(at containerPoint: CGPoint, displayedImageRect displayed: CGRect, imagePixelSize: CGSize) {
        guard displayed.contains(containerPoint),
              displayed.width > 0, displayed.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0
        else {
            setSelectedFinding(nil)
            return
        }

        let ix = (containerPoint.x - displayed.minX) / displayed.width * imagePixelSize.width
        let iy = (containerPoint.y - displayed.minY) / displayed.height * imagePixelSize.height
        setSelectedFinding(Self.findingId(atImagePoint: CGPoint(x: ix, y: iy), in: findings))
    }

    private func setSelectedFinding(_ id: UUID?) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selectedFindingId = id
        }
    }

    // MARK: - Helpers

    private func formatLength(_ meters: Float) -> String {
        MeasurementUnit.formatFlattenDistance(meters: meters, unit: measurementUnit)
    }

    private func formatDegrees(_ degrees: CGFloat) -> String {
        "\(Double(degrees).formatted(.number.precision(.fractionLength(0))))°"
    }

    /// The legend card is an obstacle for exterior lines, and its Rotation row depends on
    /// those lines, so lay out once with three rows and again with four if the row is needed.
    private func selectionLayout(
        for finding: FlattenShapeFinding,
        imageToView: CGAffineTransform,
        displayedImageRect: CGRect,
        container: CGSize,
        safeInsets: EdgeInsets
    ) -> SelectionLayout {
        let anchor = finding.boundingRectImage.applying(imageToView)
        let otherFindings = findings.filter { $0.id != finding.id }

        func layout(showsRotation: Bool) -> SelectionLayout {
            let popupSize = CGSize(
                width: Style.popupWidth,
                height: Style.popupBaseHeight + (showsRotation ? Style.popupRowHeight : 0)
            )
            let center = Self.popupCenter(
                anchorRect: anchor,
                popupSize: popupSize,
                container: container,
                safeInsets: safeInsets
            )
            let legendRect = CGRect(
                x: center.x - popupSize.width / 2,
                y: center.y - popupSize.height / 2,
                width: popupSize.width,
                height: popupSize.height
            )
            let obstacles = FlattenDimensionLayout.Obstacles(findings: otherFindings, rects: [legendRect])
            func placement(for axis: FlattenDimensionLayout.Axis) -> FlattenDimensionPlacement {
                FlattenDimensionLayout.layout(
                    for: axis,
                    of: finding,
                    imageToView: imageToView,
                    viewBounds: displayedImageRect,
                    obstacles: obstacles
                )
            }
            return SelectionLayout(
                popupCenter: center,
                width: placement(for: .width),
                height: placement(for: .height),
                showsRotation: showsRotation
            )
        }

        let threeRowLayout = layout(showsRotation: false)
        let needsRotation = FlattenDimensionLayout.shouldShowRotation(
            for: finding,
            placements: [threeRowLayout.width, threeRowLayout.height]
        )
        return needsRotation ? layout(showsRotation: true) : threeRowLayout
    }

    /// Places the popup above the box when there is room, otherwise below; clamps to safe area.
    private static func popupCenter(
        anchorRect r: CGRect,
        popupSize: CGSize,
        container: CGSize,
        safeInsets: EdgeInsets
    ) -> CGPoint {
        let margin: CGFloat = 14
        let popupW = popupSize.width
        let popupH = popupSize.height
        let gap: CGFloat = 10

        var x = r.midX
        let yAbove = r.minY - gap - popupH * 0.5
        let minY = safeInsets.top + margin + popupH * 0.5
        let maxY = container.height - safeInsets.bottom - margin - popupH * 0.5
        var y: CGFloat
        if yAbove >= minY {
            y = yAbove
        } else {
            y = r.maxY + gap + popupH * 0.5
            y = min(y, maxY)
        }
        y = min(max(y, minY), maxY)

        let halfW = popupW * 0.5
        x = min(max(x, margin + halfW), container.width - margin - halfW)

        return CGPoint(x: x, y: y)
    }

    private static func warpedImagePixelSize(_ image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            return CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        }
        return CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
    }

    private static func letterboxedImageRect(container: CGSize, imageAspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, imageAspect > 0 else {
            return .zero
        }
        let containerAspect = container.width / container.height
        if containerAspect > imageAspect {
            let height = container.height
            let width = height * imageAspect
            let x = (container.width - width) * 0.5
            return CGRect(x: x, y: 0, width: width, height: height)
        } else {
            let width = container.width
            let height = width / imageAspect
            let y = (container.height - height) * 0.5
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }

    /// Maps warped-image pixels to container points for the `scaledToFit` letterbox.
    private static func imageToViewTransform(
        imagePixelSize: CGSize,
        displayedInContainer displayed: CGRect
    ) -> CGAffineTransform {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              displayed.width > 0, displayed.height > 0
        else { return CGAffineTransform(scaleX: 0, y: 0) }
        return CGAffineTransform(
            a: displayed.width / imagePixelSize.width,
            b: 0,
            c: 0,
            d: displayed.height / imagePixelSize.height,
            tx: displayed.minX,
            ty: displayed.minY
        )
    }

    private static func closedPath(through points: [CGPoint]) -> Path {
        Path { path in
            guard points.count >= 2 else { return }
            path.addLines(points)
            path.closeSubpath()
        }
    }

    /// The shaft is inset by the arrowhead length so dashes never poke past the tips.
    private static func chordPaths(from start: CGPoint, to end: CGPoint) -> (shaft: Path, arrowheads: Path) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return (Path(), Path()) }

        let direction = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let headLength = min(Style.arrowheadLength, length / 3)
        let headHalfWidth = headLength * 0.5

        func offset(_ point: CGPoint, along axis: CGPoint, by distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + axis.x * distance, y: point.y + axis.y * distance)
        }

        let shaftStart = offset(start, along: direction, by: headLength)
        let shaftEnd = offset(end, along: direction, by: -headLength)

        let shaft = Path { path in
            path.move(to: shaftStart)
            path.addLine(to: shaftEnd)
        }
        let arrowheads = Path { path in
            for (tip, base) in [(start, shaftStart), (end, shaftEnd)] {
                path.move(to: tip)
                path.addLine(to: offset(base, along: normal, by: headHalfWidth))
                path.addLine(to: offset(base, along: normal, by: -headHalfWidth))
                path.closeSubpath()
            }
        }
        return (shaft, arrowheads)
    }

    /// Overlapping shapes: the smallest contour area wins. Near-equal areas use lexicographically smaller `UUID` for a stable pick.
    private static func findingId(atImagePoint point: CGPoint, in findings: [FlattenShapeFinding]) -> UUID? {
        var bestId: UUID?
        var bestArea = CGFloat.greatestFiniteMagnitude
        let tieEps: CGFloat = 1e-3
        for f in findings {
            guard f.boundingRectImage.contains(point),
                  polygon(f.contourImage, contains: point)
            else { continue }
            let area = abs(FlattenRectifiedEdgeAnalysis.signedArea(of: f.contourImage))
            if area < bestArea - tieEps {
                bestArea = area
                bestId = f.id
            } else if abs(area - bestArea) <= tieEps {
                if bestId == nil || f.id.uuidString < bestId!.uuidString {
                    bestArea = area
                    bestId = f.id
                }
            }
        }
        return bestId
    }

    /// Even–odd ray cast, so a repeated closing vertex is harmless.
    private static func polygon(_ vertices: [CGPoint], contains point: CGPoint) -> Bool {
        guard vertices.count >= 3 else { return false }
        var isInside = false
        var previous = vertices[vertices.count - 1]
        for current in vertices {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossingX = current.x + (point.y - current.y) * (previous.x - current.x) / (previous.y - current.y)
                if point.x < crossingX {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }
}
