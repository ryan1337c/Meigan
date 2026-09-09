//
//  FlattenWarpResultInspectOverlay.swift
//  Meigan
//

import SwiftUI
import UIKit

/// Full-color warped result with SwiftUI vector box strokes aligned to `scaledToFit` letterboxing; tap maps to image pixels (smallest clipped bbox wins on overlap).
struct FlattenWarpResultInspectOverlay: View {
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

    var body: some View {
        GeometryReader { geo in
            let container = CGSize(width: geo.size.width, height: geo.size.height)
            let pixelSize = Self.warpedImagePixelSize(image)
            let imageAspect = pixelSize.width / max(pixelSize.height, 1)
            let displayed = Self.letterboxedImageRect(container: container, imageAspect: imageAspect)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ZStack(alignment: .topLeading) {
                    ForEach(findings) { finding in
                        let r = Self.viewRect(
                            forImageRect: finding.boundingRectImage,
                            imagePixelSize: pixelSize,
                            displayedInContainer: displayed
                        )
                        let isSelected = finding.id == selectedFindingId
                        Rectangle()
                            .stroke(Color.black.opacity(0.8), lineWidth: isSelected ? 5.5 : 4)
                            .overlay(
                                Rectangle()
                                    .stroke(isSelected ? Color.yellow : Color.cyan, lineWidth: isSelected ? 3.5 : 2.25)
                            )
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }

                    if let selected = findings.first(where: { $0.id == selectedFindingId }) {
                        let anchor = Self.viewRect(
                            forImageRect: selected.boundingRectImage,
                            imagePixelSize: pixelSize,
                            displayedInContainer: displayed
                        )
                        let center = Self.popupCenter(
                            anchorRect: anchor,
                            container: container,
                            safeInsets: geo.safeAreaInsets
                        )
                        selectionPopup(for: selected)
                            .position(x: center.x, y: center.y)
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

    /// Warped bitmap plus boxes/labels in image pixel space (what Save/Share must write, not `image` alone).
    private func exportImageForAlbum() -> UIImage {
        FlattenWarpedExportImage.imageWithOverlays(
            base: image,
            findings: findings,
            unit: measurementUnit,
            highlightedFindingId: selectedFindingId
        )
    }

    /// Floating card next to the focused bounding box.
    private func selectionPopup(for finding: FlattenShapeFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected region")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                metricRow(label: "Width", value: formatLength(finding.widthMeters))
                metricRow(label: "Height", value: formatLength(finding.heightMeters))
                metricRow(label: "Perimeter", value: formatLength(finding.perimeterMeters))
            }
            .font(.subheadline.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 200, maxWidth: 260, alignment: .leading)
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

    private func metricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Places the popup above the box when there is room, otherwise below; clamps to safe area.
    private static func popupCenter(
        anchorRect r: CGRect,
        container: CGSize,
        safeInsets: EdgeInsets
    ) -> CGPoint {
        let margin: CGFloat = 14
        let popupW: CGFloat = 260
        let popupH: CGFloat = 132
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

    private func formatLength(_ meters: Float) -> String {
        MeasurementUnit.formatFlattenDistance(meters: meters, unit: measurementUnit)
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

    private static func viewRect(
        forImageRect imageRect: CGRect,
        imagePixelSize: CGSize,
        displayedInContainer displayed: CGRect
    ) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              displayed.width > 0, displayed.height > 0
        else { return .zero }
        let sx = displayed.width / imagePixelSize.width
        let sy = displayed.height / imagePixelSize.height
        return CGRect(
            x: displayed.minX + imageRect.minX * sx,
            y: displayed.minY + imageRect.minY * sy,
            width: imageRect.width * sx,
            height: imageRect.height * sy
        )
    }

    /// Overlapping boxes: smallest clipped `boundingRectImage` area wins (matches plan). Near-equal areas use lexicographically smaller `UUID` for a stable pick.
    private static func findingId(atImagePoint point: CGPoint, in findings: [FlattenShapeFinding]) -> UUID? {
        var bestId: UUID?
        var bestArea = CGFloat.greatestFiniteMagnitude
        let tieEps: CGFloat = 1e-3
        for f in findings {
            guard f.boundingRectImage.contains(point) else { continue }
            let area = f.boundingRectImage.width * f.boundingRectImage.height
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
}
