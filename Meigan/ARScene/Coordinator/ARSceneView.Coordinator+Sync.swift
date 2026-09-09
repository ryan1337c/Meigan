//
//  ARSceneView.Coordinator+Sync.swift
//  Meigan
//
//  Measurement entity setup and SwiftUI → coordinator sync (tokens, unit, mode, footer height).
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

extension ARSceneView.Coordinator {
    // MARK: - Measurements (committed segments, draft preview, 3D label)

    func setupMeasurementEntities(in arView: ARView) {
        let anchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(anchor)
        measurementAnchor = anchor

        let sphereRadius: Float = 0.006
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)

        let dashThickness: Float = 0.002
        lineDashSegmentMesh = MeshResource.generateBox(size: SIMD3<Float>(dashThickness, 1.0, dashThickness))

        let committedContainerLines = Entity()
        committedContainerLines.isEnabled = false
        let previewContainer = Entity()
        previewContainer.isEnabled = false
        let markersContainer = Entity()
        markersContainer.isEnabled = false

        let committedLabelsContainer = Entity()
        committedLabelsContainer.isEnabled = false

        let draftLabelRoot = Entity()
        draftLabelRoot.isEnabled = false

        let draftPillMesh = MeshResource.generatePlane(
            width: MeasurementLabelStyle.pillWidth,
            depth: MeasurementLabelStyle.pillHeight
        )
        let draftPill = ModelEntity(mesh: draftPillMesh, materials: [MeasurementLabelStyle.borderedPillMaterial()])
        draftPill.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        draftPill.position = SIMD3<Float>(0, 0, -0.0006)

        let draftText = ModelEntity()
        draftText.position = .zero
        draftText.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        draftLabelRoot.addChild(draftPill)
        draftLabelRoot.addChild(draftText)

        let midDotRadius: Float = 0.007
        let midDotMesh = MeshResource.generateSphere(radius: midDotRadius)
        var midDotMat = UnlitMaterial()
        midDotMat.color = .init(tint: UIColor(white: 0.96, alpha: 1))
        let midDot = ModelEntity(mesh: midDotMesh, materials: [midDotMat])
        midDot.isEnabled = false

        let fillPreview = Entity()
        fillPreview.isEnabled = false

        let committedContainerFill = Entity()
        committedContainerFill.isEnabled = false

        anchor.addChild(committedContainerLines)
        anchor.addChild(previewContainer)
        anchor.addChild(markersContainer)
        anchor.addChild(committedLabelsContainer)
        anchor.addChild(draftLabelRoot)
        anchor.addChild(midDot)
        anchor.addChild(committedContainerFill)
        anchor.addChild(fillPreview)

        committedLinesContainer = committedContainerLines
        previewLinesContainer = previewContainer
        vertexMarkersContainer = markersContainer
        markerSphereMesh = sphereMesh
        committedSegmentLabelsContainer = committedLabelsContainer
        draftPreviewLabelRoot = draftLabelRoot
        draftLabelPillEntity = draftPill
        draftLabelTextEntity = draftText
        lineMidHoverDotEntity = midDot
        flattenFillPreviewContainer = fillPreview
        committedFillContainer = committedContainerFill
    }

    /// Pass tokens from `ARSceneView.updateUIView` — coordinator-held `Binding`s for these were stale and never saw increments.
    func syncPlaceAndClearTokensIfNeeded(placeToken: Int, clearToken: Int) {
        if placeToken != lastProcessedPlaceToken {
            lastProcessedPlaceToken = placeToken
            placeMarkAtReticle()
        }
        if clearToken != lastProcessedClearToken {
            lastProcessedClearToken = clearToken
            clearAllMeasurements()
        }
    }

    func syncScreenshotTokenIfNeeded(token: Int) {
        guard token != lastProcessedScreenshotToken else { return }
        lastProcessedScreenshotToken = token
        captureScreenshotForPreview()
    }

    func syncFlattenScanTokenIfNeeded(token: Int) {
        guard token != lastProcessedFlattenScanToken else { return }
        lastProcessedFlattenScanToken = token
        guard isFlattenMode else { return }

        // `updateUIView` is a SwiftUI view update. Starting the scan mutates bindings
        // (`isFlattenScanActive`, overlay image, banner text), so defer it one turn
        // to avoid "Modifying state during view update" and to let the overlay render.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFlattenMode else { return }
            self.flattenMode.startScan()
        }
    }

    /// When Settings unit changes, refresh 3D label + readout without moving points.
    func syncMeasurementUnitFromSwiftUI(_ raw: String) {
        if raw == lastSyncedMeasurementUnitRaw { return }
        lastSyncedMeasurementUnitRaw = raw
        let unit = MeasurementUnit.from(storage: raw)

        rebuildCommittedSegmentLabelEntities()
        if draftSegmentStart != nil, let start = draftSegmentStart, let b = latestReticleWorldPosition {
            let len = simd_distance(b, start)
            guard len > 1e-5 else { return }
            let readout = MeasurementUnit.formatDistance(meters: len, unit: unit)
            let meshText = MeasurementUnit.formatDistanceForMesh3D(meters: len, unit: unit)
            lastPreviewReadoutString = ""
            rebuildDraftPreviewLabelMesh(text: meshText)
            lastPreviewReadoutString = readout
            DispatchQueue.main.async {
                self.measurementReadout = readout
            }
        } else if draftSegmentStart == nil, let last = committedSegments.last, last.lengthMeters > 1e-5 {
            let readout = MeasurementUnit.formatDistance(meters: last.lengthMeters, unit: unit)
            DispatchQueue.main.async {
                self.measurementReadout = readout
            }
        }
    }

    func syncMeasurementModeFromSwiftUI(_ raw: String) {
        guard raw != lastSyncedMeasurementModeRaw else { return }
        lastSyncedMeasurementModeRaw = raw
        clearAllMeasurements()
    }

    func syncFlattenFooterHeightFromSwiftUI(_ height: CGFloat) {
        let clamped = max(0, height)
        guard abs(clamped - lastSyncedFlattenFooterHeight) > 0.5 else { return }
        lastSyncedFlattenFooterHeight = clamped
        flattenFooterHeight = clamped
    }
}
