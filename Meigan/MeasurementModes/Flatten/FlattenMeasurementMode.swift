//
//  FlattenMeasurementMode.swift
//  Meigan
//
//  Core behavior: corner placement / readjustment, the scan lifecycle, and committed fill.
//  Split across:
//  - `+ScanQuality.swift`: quad validation (size, planarity, convexity)
//  - `+ScanImage.swift`: snapshot crop, image-plane projection, perspective correction
//  - `+ScanAnalysis.swift`: PCA plane fit, canvas fitting, homography
//  - `+Previews.swift`: draft polyline, fill polygon preview, fill mesh
//

import ARKit
import Foundation
import OSLog
import RealityKit
import simd
import UIKit

/// Debug placement / token sync; filter Console by subsystem or category `ARPlacement`.
private let arPlacementLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

/// Flatten mode: up to 4 corner points form a triangle (3 corners) or quad (4 corners) with
/// translucent fill. Locking onto a placed corner selects it for re-adjustment on the next tap.
/// The reticle snaps only to corners (not segment midpoints) plus the in-flight draft start.
final class FlattenMeasurementMode: MeasurementModeBehavior {
    weak var host: ARSceneView.Coordinator?

    init(host: ARSceneView.Coordinator) {
        self.host = host
    }

    func pinCandidates() -> [SIMD3<Float>] {
        guard let host else { return [] }
        var pins = MeasurementSegment.endpointOnlyPinpointWorldPositions(for: host.committedSegments)
        if let draft = host.draftSegmentStart {
            pins.append(draft)
        }
        return ARSceneView.Coordinator.dedupeWorldPositions(pins, tolerance: 0.005)
    }

    func resetAutolockBookkeepingIfNeeded() {
        guard let host else { return }
        if host.committedSegments.isEmpty && host.draftSegmentStart == nil {
            host.lastAutolockedPinWorld = nil
        }
    }

    func applyLineHoverAndMidDot(
        hoverPick: (index: Int, screenDist: CGFloat)?,
        threshold: CGFloat
    ) -> Int? {
        host?.lineMidHoverDotEntity?.isEnabled = false
        return nil
    }

    func updateAfterReticle(reticleWorld: SIMD3<Float>, camWorld: SIMD3<Float>, camUp: SIMD3<Float>) {
        updateFlattenDraftPreview(reticleWorld: reticleWorld)
        updateFlattenFillPreview(hoverWorld: reticleWorld)
    }

    func placeMark(at p: SIMD3<Float>) {
        guard let host else { return }

        if let adjustingIndex = host.flattenAdjustingPointIndex {
            guard host.latestPinAutolockWorld == nil else {
                arPlacementLog.notice("placeFlattenMarkAtReticle: ABORT adjusted corner target is locked to an existing corner")
                return
            }
            updateFlattenPoint(at: adjustingIndex, to: p)
            host.flattenAdjustingPointIndex = nil
            host.refreshMeasurementVisuals()
            return
        }

        if let pin = host.latestPinAutolockWorld {
            guard let pinIndex = flattenPointIndex(for: pin) else {
                host.showPlacementWarning("Move to a valid surface before placing the next Flatten point.", kind: .alert)
                return
            }
            host.flattenAdjustingPointIndex = pinIndex
            host.refreshMeasurementVisuals()
            host.showPlacementWarning(
                "Corner \(pinIndex + 1) selected — move to the new position, then tap +",
                kind: .instruction
            )
            return
        }

        guard host.committedSegments.count < 3 else {
            arPlacementLog.notice("placeFlattenMarkAtReticle: ABORT four corners already placed")
            host.showPlacementWarning("All 4 corners are placed. Lock onto a corner to readjust it.", kind: .instruction)
            return
        }

        if let start = host.draftSegmentStart {
            if simd_distance(start, p) > 1e-5 {
                host.committedSegments.append(MeasurementSegment(start: start, end: p))
            }
            host.draftSegmentStart = host.committedSegments.count >= 3 ? nil : p
        } else if let lastEnd = host.committedSegments.last?.end {
            if simd_distance(lastEnd, p) > 1e-5 {
                host.committedSegments.append(MeasurementSegment(start: lastEnd, end: p))
            }
            host.draftSegmentStart = host.committedSegments.count >= 3 ? nil : p
        } else {
            host.draftSegmentStart = p
        }

        host.refreshMeasurementVisuals()
    }

    func startScan() {
        guard let host, let arView = host.arView else {
            cancelScan(message: "Scan cancelled. AR view is not ready.")
            return
        }
        guard !host.isFlattenScanActive else { return }

        let points = Array(flattenPlacedPoints().prefix(4))
        guard points.count == 4, host.flattenAdjustingPointIndex == nil else {
            cancelScan(message: "Scan cancelled. Complete the 4 corners first.")
            return
        }

        guard allPointsVisible(points, in: arView) else {
            host.showPlacementWarning("Aim the camera so all 4 corners are visible, then tap Scan.", kind: .instruction)
            return
        }

        guard let scanFrame = arView.session.currentFrame else {
            cancelScan(message: "Scan cancelled. AR frame is not ready.")
            return
        }

        let scanOrientation = Self.interfaceOrientation(in: arView)
        let scanViewportSize = arView.bounds.size
        let imagePlanePoints = Self.projectToImagePlane(
            points,
            frame: scanFrame,
            orientation: scanOrientation,
            viewportSize: scanViewportSize
        )
        guard imagePlanePoints.count == points.count else {
            host.showPlacementWarning("Aim the camera so all 4 corners are visible, then tap Scan.", kind: .instruction)
            return
        }

        // Activate the scan overlay synchronously so the user sees instant feedback
        // the moment they tap Start Scan. The preview image fills in once the AR
        // snapshot completes; until then `FlattenScanPreviewOverlay` shows its chrome
        // with the animated scanning beam.
        host.flattenScanPreviewImage = nil
        host.flattenScanResultImage = nil
        host.flattenShapeFindings = []
        host.flattenDetectionPreviewImage = nil
        host.flattenScanSigmas = []
        host.isFlattenScanActive = true
        host.flattenScanOccludesPlacementChrome = true
        host.suppressPlacementBannerChromeDuringFlattenPipelineHandoff()

        host.beginFlattenScanSnapshotDecorations()
        host.applyFlattenScanPreviewSnapshotVisibility()
        arView.snapshot(saveToHDR: false) { [weak self, weak host, weak arView] previewFull in
            DispatchQueue.main.async { [weak self, weak host, weak arView, previewFull] in
                guard let host else { return }
                guard let self, let arView else {
                    host.flattenScanOccludesPlacementChrome = false
                    host.restoreFlattenScanSnapshotDecorations()
                    host.isFlattenScanActive = false
                    host.flattenScanPreviewImage = nil
                    return
                }
                host.applyFlattenScanRawSnapshotVisibility()
                arView.snapshot(saveToHDR: false) { [weak self, weak host, weak arView, previewFull] rawFull in
                    DispatchQueue.main.async { [weak self, weak host, weak arView, previewFull] in
                        guard let host else { return }
                        host.restoreFlattenScanSnapshotDecorations()
                        guard let self, let arView else {
                            host.flattenScanOccludesPlacementChrome = false
                            host.isFlattenScanActive = false
                            host.flattenScanPreviewImage = nil
                            return
                        }
                        guard let previewFull, let rawFull else {
                            host.flattenScanOccludesPlacementChrome = false
                            host.isFlattenScanActive = false
                            host.flattenScanPreviewImage = nil
                            host.showPlacementWarning("Scan cancelled. Could not capture the AR view.", kind: .alert)
                            return
                        }
                        let currentPoints = Array(self.flattenPlacedPoints().prefix(4))
                        guard Self.pointsMatch(points, currentPoints),
                              self.allPointsVisible(currentPoints, in: arView)
                        else {
                            host.flattenScanOccludesPlacementChrome = false
                            host.isFlattenScanActive = false
                            host.flattenScanPreviewImage = nil
                            host.showPlacementWarning("Aim the camera so all 4 corners are visible, then tap Scan.", kind: .instruction)
                            return
                        }

                        let previewImage = Self.croppedScanImage(from: previewFull, around: currentPoints, in: arView)
                        self.beginScan(
                            with: previewImage,
                            sourceImage: rawFull,
                            points: currentPoints,
                            imagePlanePoints: imagePlanePoints,
                            viewportSize: scanViewportSize,
                            in: arView
                        )
                    }
                }
            }
        }
    }

    private func beginScan(
        with previewImage: UIImage,
        sourceImage: UIImage,
        points: [SIMD3<Float>],
        imagePlanePoints: [SIMD2<Float>],
        viewportSize: CGSize,
        in arView: ARView
    ) {
        guard let host else {
            cancelScan(message: "Scan cancelled. AR view is not ready.")
            return
        }

        let completionToken = host.flattenScanInvalidateGeneration

        host.flattenScanPreviewImage = previewImage
        host.flattenScanResultImage = nil
        host.flattenShapeFindings = []
        host.flattenDetectionPreviewImage = nil
        host.flattenScanSigmas = []
        host.isFlattenScanActive = true
        host.flattenScanOccludesPlacementChrome = false
        host.clearFlattenLiveMeasurementAfterSuccessfulScan()

        let canvasSize = Self.scanCanvasSize(in: arView, footerHeight: host.flattenFooterHeight)
        let measurementUnit = MeasurementUnit.from(storage: host.measurementUnitRaw)
        DispatchQueue.global(qos: .utility).async { [weak host] in
            let result = autoreleasepool {
                let analysis = Self.scanAnalysis(
                    for: points,
                    imagePlanePoints: imagePlanePoints,
                    outputCanvasSize: canvasSize,
                    measurementUnit: measurementUnit
                )
                let outcome = Self.FlattenScanQuality.evaluate(analysis: analysis, points: points)
                let warpedImage: UIImage?
                switch outcome {
                case .success:
                    warpedImage = Self.inverseWarpQuadImage(
                        from: sourceImage,
                        analysis: analysis,
                        viewportSize: viewportSize
                    )
                case .failure:
                    warpedImage = nil
                }
                let shapeDetection: FlattenShapeDetectionResult = {
                    guard let warpedImage else {
                        return FlattenShapeDetectionResult(findings: [], detectionPreviewImage: nil)
                    }
                    let renderedPixelsPerMeter = Self.renderedPixelsPerMeter(
                        for: warpedImage,
                        analysis: analysis
                    )
                    return FlattenRectifiedEdgeAnalysis.detectShapes(
                        for: warpedImage,
                        pixelsPerMeter: renderedPixelsPerMeter
                    )
                }()
                return (analysis, outcome, warpedImage, shapeDetection)
            }
            let minimumAnimationDuration: TimeInterval = 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumAnimationDuration) { [weak host] in
                guard let host else { return }
                guard host.flattenScanInvalidateGeneration == completionToken else {
                    // Scan invalidated (clear marks, new scan, etc.): drop in-flight result state.
                    host.flattenScanOccludesPlacementChrome = false
                    host.isFlattenScanActive = false
                    host.flattenScanPreviewImage = nil
                    host.flattenScanResultImage = nil
                    host.flattenShapeFindings = []
                    host.flattenDetectionPreviewImage = nil
                    return
                }

                let (analysis, outcome, warpedImage, shapeDetection) = result
                host.flattenScanSigmas = analysis.singularValues
                host.isFlattenScanActive = false
                host.flattenScanOccludesPlacementChrome = false
                host.flattenScanPreviewImage = nil
                switch outcome {
                case .success:
                    guard let warpedImage else {
                        host.showPlacementWarning("Scan failed. Could not render the flattened canvas.", kind: .alert)
                        return
                    }
                    host.flattenScanResultImage = warpedImage
                    host.flattenShapeFindings = shapeDetection.findings
                    host.flattenDetectionPreviewImage = shapeDetection.detectionPreviewImage
                    host.showPlacementWarning(Self.scanCompleteMessage(sigmas: analysis.singularValues), kind: .instruction)
                case .failure(let message):
                    host.showPlacementWarning(message, kind: .alert)
                }
            }
        }
    }

    func rebuildCommittedFillGeometry() {
        guard let host, let container = host.committedFillContainer else { return }
        host.clearEntityChildren(container)

        arPlacementLog.notice("rebuildCommittedFillGeometry: isFlattenMode=true segCount=\(host.committedSegments.count)")

        guard !host.committedSegments.isEmpty else {
            container.isEnabled = false
            arPlacementLog.notice("rebuildCommittedFillGeometry: ABORT no segments")
            return
        }

        let segCount = host.committedSegments.count
        var points: [SIMD3<Float>] = []

        if segCount >= 1 {
            points.append(host.committedSegments[0].start)
            points.append(host.committedSegments[0].end)
        }
        if segCount >= 2 {
            points.append(host.committedSegments[1].end)
        }
        if segCount >= 3 {
            points.append(host.committedSegments[2].end)
        }

        arPlacementLog.notice("rebuildCommittedFillGeometry: points.count=\(points.count)")

        guard points.count >= 3 else {
            container.isEnabled = false
            arPlacementLog.notice("rebuildCommittedFillGeometry: ABORT insufficient points for fill")
            return
        }

        if let entity = makeFlattenFillEntity(points: points) {
            container.addChild(entity)
            container.isEnabled = true
            arPlacementLog.notice("rebuildCommittedFillGeometry: ✅ fill entity created and enabled")
        } else {
            container.isEnabled = false
            arPlacementLog.notice("rebuildCommittedFillGeometry: ❌ makeFlattenFillEntity returned nil")
        }
    }

    // MARK: - Scan lifecycle helpers

    private func cancelScan(message: String) {
        guard let host else { return }
        DispatchQueue.main.async {
            host.flattenScanInvalidateGeneration += 1
            host.flattenScanOccludesPlacementChrome = false
            host.isFlattenScanActive = false
            host.flattenScanPreviewImage = nil
            host.flattenScanSigmas = []
            host.showPlacementWarning(message, kind: .alert)
        }
    }

    private static func scanCompleteMessage(sigmas: [Float]) -> String {
        let values = sigmas.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        return "Scan complete. sigmas: \(values)"
    }

    // MARK: - Corner bookkeeping

    private static func pointsMatch(_ lhs: [SIMD3<Float>], _ rhs: [SIMD3<Float>]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { simd_distance($0, $1) < 0.0005 }
    }

    private func allPointsVisible(_ points: [SIMD3<Float>], in arView: ARView) -> Bool {
        guard points.count == 4 else { return false }
        let bounds = arView.bounds.insetBy(dx: 12, dy: 12)
        return points.allSatisfy { point in
            guard let projected = arView.project(point) else { return false }
            return bounds.contains(projected)
        }
    }

    /// True when the quad is complete and every corner projects inside the AR view (same gate as `startScan`).
    func scanCornersVisible(in arView: ARView) -> Bool {
        let points = Array(flattenPlacedPoints().prefix(4))
        guard points.count == 4 else { return false }
        return allPointsVisible(points, in: arView)
    }

    func flattenPlacedPoints() -> [SIMD3<Float>] {
        guard let host else { return [] }
        if !host.committedSegments.isEmpty {
            return MeasurementSegment.endpointOnlyPinpointWorldPositions(for: host.committedSegments)
        }
        if let draftSegmentStart = host.draftSegmentStart {
            return [draftSegmentStart]
        }
        return []
    }

    private func flattenPointIndex(for pin: SIMD3<Float>) -> Int? {
        let points = flattenPlacedPoints()
        return points.enumerated().min(by: {
            simd_distance($0.element, pin) < simd_distance($1.element, pin)
        }).flatMap { index, point in
            simd_distance(point, pin) < 0.006 ? index : nil
        }
    }

    private func updateFlattenPoint(at index: Int, to point: SIMD3<Float>) {
        var points = flattenPlacedPoints()
        guard points.indices.contains(index) else { return }
        points[index] = point
        rebuildFlattenSegments(from: points)
    }

    private func rebuildFlattenSegments(from points: [SIMD3<Float>]) {
        guard let host else { return }
        host.committedSegments.removeAll()
        guard !points.isEmpty else {
            host.draftSegmentStart = nil
            return
        }

        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                if simd_distance(points[i], points[i + 1]) > 1e-5 {
                    host.committedSegments.append(MeasurementSegment(start: points[i], end: points[i + 1]))
                }
            }
        }

        host.draftSegmentStart = points.count >= 4 ? nil : points.last
    }
}
