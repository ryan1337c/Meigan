//
//  ARSceneView.Coordinator+Snapshots.swift
//  Meigan
//
//  AR screenshot capture (with Identify annotations) and flatten dual-snapshot decoration toggling.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

extension ARSceneView.Coordinator {
    /// Renders the AR view to an image; parent shows preview and runs Save / Share only after explicit confirmation.
    func captureScreenshotForPreview() {
        guard !placementBannerChromeMutedForFlattenCapture else { return }
        guard let arView = arView else { return }
        let identifyAnnotations = isIdentifyMode ? appliedIdentifyDetections : []
        let viewportSize = arView.bounds.size
        arView.snapshot(saveToHDR: false) { [weak self] image in
            guard let self, let image else { return }
            let previewImage = Self.drawingIdentifyAnnotations(
                identifyAnnotations,
                on: image,
                viewportSize: viewportSize
            )
            DispatchQueue.main.async {
                self.screenshotPreviewImage = previewImage
            }
        }
    }

    /// Composites the screen-space Identify overlay onto an AR snapshot.
    /// Detection rectangles use ARView points, while the snapshot can have a
    /// different logical size, so each axis is scaled independently.
    private static func drawingIdentifyAnnotations(
        _ detections: [IdentifyDetection],
        on image: UIImage,
        viewportSize: CGSize
    ) -> UIImage {
        guard !detections.isEmpty,
              image.size.width > 0, image.size.height > 0,
              viewportSize.width > 0, viewportSize.height > 0
        else { return image }

        let scaleX = image.size.width / viewportSize.width
        let scaleY = image.size.height / viewportSize.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))

            let cgContext = context.cgContext
            let strokeWidth = 2 * min(scaleX, scaleY)

            let baseFont = UIFont.preferredFont(forTextStyle: .caption2)
            let font = UIFont.systemFont(
                ofSize: baseFont.pointSize * min(scaleX, scaleY),
                weight: .semibold
            )
            let horizontalPadding = 5 * scaleX
            let verticalPadding = 2 * scaleY

            for detection in detections {
                let rect = CGRect(
                    x: detection.viewRect.minX * scaleX,
                    y: detection.viewRect.minY * scaleY,
                    width: detection.viewRect.width * scaleX,
                    height: detection.viewRect.height * scaleY
                )
                // Text drawing mutates CGContext stroke/fill; reset green each iteration.
                cgContext.setStrokeColor(UIColor.green.cgColor)
                cgContext.setLineWidth(strokeWidth)
                cgContext.stroke(rect)

                let text = "\(detection.label) \(Int(detection.confidence * 100))%" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.black
                ]
                let textSize = text.size(withAttributes: attributes)
                let labelRect = CGRect(
                    x: rect.minX,
                    y: rect.minY - textSize.height - (verticalPadding * 2),
                    width: textSize.width + (horizontalPadding * 2),
                    height: textSize.height + (verticalPadding * 2)
                )

                cgContext.setFillColor(UIColor.green.cgColor)
                cgContext.fill(labelRect)
                text.draw(
                    at: CGPoint(
                        x: labelRect.minX + horizontalPadding,
                        y: labelRect.minY + verticalPadding
                    ),
                    withAttributes: attributes
                )
            }
        }
    }

    func beginFlattenScanSnapshotDecorations() {
        if flattenScanSnapshotDecorationRestore != nil {
            restoreFlattenScanSnapshotDecorations()
        }
        isFlattenScanSnapshotCaptureActive = true
        flattenScanSnapshotDecorationRestore = FlattenScanSnapshotDecorationRestore(
            ring: ringEntity?.isEnabled ?? false,
            hasValidTarget: hasValidTarget,
            committedLines: committedLinesContainer?.isEnabled ?? false,
            committedFill: committedFillContainer?.isEnabled ?? false,
            segmentLabels: committedSegmentLabelsContainer?.isEnabled ?? false,
            draftLabel: draftPreviewLabelRoot?.isEnabled ?? false,
            flattenFillPreview: flattenFillPreviewContainer?.isEnabled ?? false,
            previewLines: previewLinesContainer?.isEnabled ?? false,
            vertexMarkers: vertexMarkersContainer?.isEnabled ?? false,
            lineMidHoverDot: lineMidHoverDotEntity?.isEnabled ?? false
        )
    }

    /// Preview still: committed teal fill + dashed edge lines only (no labels, markers, ring, draft UI).
    func applyFlattenScanPreviewSnapshotVisibility() {
        ringEntity?.isEnabled = false
        hasValidTarget = false
        committedSegmentLabelsContainer?.isEnabled = false
        draftPreviewLabelRoot?.isEnabled = false
        lineMidHoverDotEntity?.isEnabled = false
        vertexMarkersContainer?.isEnabled = false
        flattenFillPreviewContainer?.isEnabled = false
        previewLinesContainer?.isEnabled = false
        committedLinesContainer?.isEnabled = true
        committedFillContainer?.isEnabled = true
    }

    /// Final warp / export: camera-only (no measurement overlays).
    func applyFlattenScanRawSnapshotVisibility() {
        ringEntity?.isEnabled = false
        hasValidTarget = false
        committedLinesContainer?.isEnabled = false
        committedFillContainer?.isEnabled = false
        committedSegmentLabelsContainer?.isEnabled = false
        draftPreviewLabelRoot?.isEnabled = false
        flattenFillPreviewContainer?.isEnabled = false
        previewLinesContainer?.isEnabled = false
        vertexMarkersContainer?.isEnabled = false
        lineMidHoverDotEntity?.isEnabled = false
    }

    func restoreFlattenScanSnapshotDecorations() {
        isFlattenScanSnapshotCaptureActive = false
        guard let snapshot = flattenScanSnapshotDecorationRestore else { return }
        flattenScanSnapshotDecorationRestore = nil
        ringEntity?.isEnabled = snapshot.ring
        hasValidTarget = snapshot.hasValidTarget
        committedLinesContainer?.isEnabled = snapshot.committedLines
        committedFillContainer?.isEnabled = snapshot.committedFill
        committedSegmentLabelsContainer?.isEnabled = snapshot.segmentLabels
        draftPreviewLabelRoot?.isEnabled = snapshot.draftLabel
        flattenFillPreviewContainer?.isEnabled = snapshot.flattenFillPreview
        previewLinesContainer?.isEnabled = snapshot.previewLines
        vertexMarkersContainer?.isEnabled = snapshot.vertexMarkers
        lineMidHoverDotEntity?.isEnabled = snapshot.lineMidHoverDot
    }

    /// Clears flatten quad/lines/labels from the live scene after a **successful** scan (not used on cancel).
    func clearFlattenLiveMeasurementAfterSuccessfulScan() {
        committedSegments.removeAll()
        draftSegmentStart = nil
        flattenAdjustingPointIndex = nil
        lastFlattenScanCornersReady = false
        committedLinesContainer?.isEnabled = false
        previewLinesContainer?.isEnabled = false
        clearEntityChildren(committedLinesContainer)
        clearEntityChildren(previewLinesContainer)
        clearEntityChildren(vertexMarkersContainer)
        clearEntityChildren(committedSegmentLabelsContainer)
        clearEntityChildren(committedFillContainer)
        committedFillContainer?.isEnabled = false
        committedSegmentLabelsContainer?.isEnabled = false
        draftPreviewLabelRoot?.isEnabled = false
        draftPreviewLabelRoot?.scale = SIMD3<Float>(repeating: 1)
        lineMidHoverDotEntity?.isEnabled = false
        clearEntityChildren(flattenFillPreviewContainer)
        flattenFillPreviewContainer?.isEnabled = false
        lastAutolockedPinWorld = nil
        latestPinAutolockWorld = nil
        lastPreviewReadoutString = ""
        hideRing()
        DispatchQueue.main.async {
            self.measurementReadout = "—"
            self.markCount = 0
            self.flattenSegmentCount = 0
            self.flattenRelocationActive = false
            self.flattenScanCornersReady = false
        }
    }
}
