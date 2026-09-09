//
//  ARSceneView.Coordinator+Measurements.swift
//  Meigan
//
//  Placing / clearing marks and rebuilding committed lines, vertex markers, dotted previews, and labels.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

extension ARSceneView.Coordinator {
    func placeMarkAtReticle() {
        if placementBannerChromeMutedForFlattenCapture {
            return
        }
        let resolvedIssue = resolveMergedTrackingGuideIssue()
        if resolvedIssue != .none {
            let guidance = messageAndReason(for: resolvedIssue)
            if !guidance.message.isEmpty {
                showPlacementWarning(guidance.message)
            }
            return
        }
        guard let p = latestReticleWorldPosition else {
            return
        }
        currentMode.placeMark(at: p)
    }

    func showPlacementWarning(_ message: String, kind: PlacementBannerKind = .alert) {
        if placementBannerChromeMutedForFlattenCapture {
            return
        }
        if kind == .alert, hapticFeedbackEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        DispatchQueue.main.async {
            self.placementBannerKind = kind
            self.placementWarningMessage = message
            self.placementWarningToken += 1
        }
    }

    func clearAllMeasurements() {
        identifyMode.resetTracks()
        if !identifyDetections.isEmpty {
            DispatchQueue.main.async { self.identifyDetections = [] }
        }

        if isFlattenScanActive {
            flattenScanInvalidateGeneration += 1
            DispatchQueue.main.async {
                self.flattenScanOccludesPlacementChrome = false
                self.isFlattenScanActive = false
                self.flattenScanPreviewImage = nil
                self.flattenScanResultImage = nil
                self.flattenScanSigmas = []
                self.flattenShapeFindings = []
                self.flattenDetectionPreviewImage = nil
            }
            return
        }


        flattenScanInvalidateGeneration += 1
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
        DispatchQueue.main.async {
            self.flattenScanOccludesPlacementChrome = false
            self.measurementReadout = "—"
            self.markCount = 0
            self.flattenSegmentCount = 0
            self.flattenRelocationActive = false
            self.isFlattenScanActive = false
            self.flattenScanPreviewImage = nil
            self.flattenScanResultImage = nil
            self.flattenShapeFindings = []
            self.flattenDetectionPreviewImage = nil
            self.flattenScanSigmas = []
            self.flattenScanCornersReady = false
        }
    }

    func clearEntityChildren(_ entity: Entity?) {
        guard let entity else { return }
        for child in Array(entity.children) {
            child.removeFromParent()
        }
    }

    private func rebuildCommittedLineGeometry() {
        guard let container = committedLinesContainer, let mesh = lineDashSegmentMesh else { return }
        clearEntityChildren(container)
        guard !committedSegments.isEmpty else { return }
        var mat = UnlitMaterial()
        mat.color = .init(tint: .white.withAlphaComponent(1.0))
        let materials: [RealityKit.Material] = [mat]
        for seg in committedSegments {
            let delta = seg.end - seg.start
            let len = simd_length(delta)
            guard len > 1e-5 else { continue }
            let dir = delta / len
            let center = seg.start + dir * (len * 0.5)
            let beam = ModelEntity(mesh: mesh, materials: materials)
            beam.position = center
            beam.orientation = Self.quatAligningPositiveY(to: dir)
            beam.scale = SIMD3<Float>(1, len, 1)
            container.addChild(beam)
        }
    }

    private func rebuildVertexMarkerEntities() {
        guard let container = vertexMarkersContainer, let mesh = markerSphereMesh else { return }
        clearEntityChildren(container)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(committedSegments.count * 2 + 1)
        for s in committedSegments {
            positions.append(s.start)
            positions.append(s.end)
        }
        if let d = draftSegmentStart {
            positions.append(d)
        }
        let deduped = Self.dedupeWorldPositions(positions, tolerance: 0.005)
        guard !deduped.isEmpty else {
            container.isEnabled = false
            return
        }
        var mat = UnlitMaterial()
        mat.color = .init(tint: .white)
        let materials: [RealityKit.Material] = [mat]
        for pos in deduped {
            let e = ModelEntity(mesh: mesh, materials: materials)
            e.position = pos
            container.addChild(e)
        }
        container.isEnabled = true
    }

    func rebuildCommittedSegmentLabelEntities() {
        guard let container = committedSegmentLabelsContainer else { return }
        clearEntityChildren(container)
        let unit = MeasurementUnit.from(storage: measurementUnitRaw)
        for seg in committedSegments {
            let text: String
            if seg.lengthMeters > 1e-5 {
                text = MeasurementUnit.formatDistanceForMesh3D(meters: seg.lengthMeters, unit: unit)
            } else {
                text = "-"
            }
            container.addChild(Self.makeMeasurementLabelStack(displayText: text))
        }
        container.isEnabled = !committedSegments.isEmpty
    }

    /// White dotted line: skinny boxes along `dir` from `a` for `length` meters.
    private func rebuildDottedLine(from a: SIMD3<Float>, direction dir: SIMD3<Float>, length len: Float, in container: Entity) {
        clearEntityChildren(container)
        addDottedLine(from: a, direction: dir, length: len, in: container)
    }

    func addDottedLine(from a: SIMD3<Float>, to b: SIMD3<Float>, in container: Entity) {
        let delta = b - a
        let len = simd_length(delta)
        guard len > 1e-5 else { return }
        addDottedLine(from: a, direction: delta / len, length: len, in: container)
    }

    func addDottedLine(from a: SIMD3<Float>, direction dir: SIMD3<Float>, length len: Float, in container: Entity) {
        guard let mesh = lineDashSegmentMesh else { return }
        var mat = UnlitMaterial()
        mat.color = .init(tint: .white.withAlphaComponent(0.95))
        let materials: [RealityKit.Material] = [mat]
        let orientation = Self.quatAligningPositiveY(to: dir)
        let dashLen: Float = 0.017
        let gapLen: Float = 0.012
        var t: Float = 0
        while t < len {
            let remaining = len - t
            let segLen = min(dashLen, remaining)
            if segLen < 0.0005 { break }
            let center = a + dir * (t + segLen * 0.5)
            let dash = ModelEntity(mesh: mesh, materials: materials)
            dash.position = center
            dash.orientation = orientation
            dash.scale = SIMD3<Float>(1, segLen, 1)
            container.addChild(dash)
            t += segLen + gapLen
        }
    }

    func clearSingleMarkPreviewVisuals() {
        guard draftSegmentStart != nil else { return }
        previewLinesContainer?.isEnabled = false
        clearEntityChildren(previewLinesContainer)
        draftPreviewLabelRoot?.isEnabled = false
        lastPreviewReadoutString = ""
        DispatchQueue.main.async {
            self.measurementReadout = "—"
        }
    }

    /// Dotted preview from draft start to current reticle while placing the free end.
    func updatePreviewLineAndLabel(reticleWorld: SIMD3<Float>, camWorld: SIMD3<Float>, camUp: SIMD3<Float>) {
        guard let start = draftSegmentStart,
              let lineContainer = previewLinesContainer,
              let labelRoot = draftPreviewLabelRoot
        else { return }

        let a = start
        let b = reticleWorld
        let delta = b - a
        let len = simd_length(delta)
        guard len > 1e-5 else {
            clearSingleMarkPreviewVisuals()
            return
        }
        let dir = delta / len

        rebuildDottedLine(from: a, direction: dir, length: len, in: lineContainer)
        lineContainer.isEnabled = true

        let labelPos = Self.measurementLabelWorldPosition(segmentFrom: a, segmentTo: b, cameraWorld: camWorld)
        let s = Self.measurementLabelUniformScaleForFixedScreenSize(
            cameraWorld: camWorld,
            labelWorldPosition: labelPos
        )
        labelRoot.position = labelPos
        labelRoot.scale = SIMD3<Float>(repeating: s)
        labelRoot.orientation = Self.measurementLabelViewAlignedQuaternion(
            labelPosition: labelPos,
            segmentFrom: a,
            segmentTo: b,
            cameraWorld: camWorld,
            cameraUpWorld: camUp
        )

        let unit = MeasurementUnit.from(storage: measurementUnitRaw)
        let readout = MeasurementUnit.formatDistance(meters: len, unit: unit)
        if readout != lastPreviewReadoutString {
            lastPreviewReadoutString = readout
            rebuildDraftPreviewLabelMesh(text: MeasurementUnit.formatDistanceForMesh3D(meters: len, unit: unit))
            DispatchQueue.main.async {
                self.measurementReadout = readout
            }
        }

        labelRoot.isEnabled = true
    }

    func refreshMeasurementVisuals() {
        guard let committedC = committedLinesContainer,
              let previewC = previewLinesContainer,
              vertexMarkersContainer != nil,
              committedSegmentLabelsContainer != nil,
              draftPreviewLabelRoot != nil,
              draftLabelPillEntity != nil,
              draftLabelTextEntity != nil
        else {
            return
        }

        let unit = MeasurementUnit.from(storage: measurementUnitRaw)

        rebuildCommittedLineGeometry()
        rebuildVertexMarkerEntities()
        rebuildCommittedSegmentLabelEntities()
        currentMode.rebuildCommittedFillGeometry()

        let rawSegmentCount = self.committedSegments.count
        let publishedFlattenCount = self.flattenAdjustingPointIndex != nil ? 0 : rawSegmentCount
        DispatchQueue.main.async {
            if self.flattenSegmentCount != publishedFlattenCount {
                self.flattenSegmentCount = publishedFlattenCount
            }
            self.flattenRelocationActive = (self.flattenAdjustingPointIndex != nil)
        }

        clearEntityChildren(previewC)
        previewC.isEnabled = false

        if committedSegments.isEmpty, draftSegmentStart == nil {
            committedC.isEnabled = false
            lineMidHoverDotEntity?.isEnabled = false
            draftPreviewLabelRoot?.isEnabled = false
            lastPreviewReadoutString = ""
            DispatchQueue.main.async {
                self.measurementReadout = "—"
                self.markCount = 0
            }
            return
        }

        committedC.isEnabled = !committedSegments.isEmpty

        if draftSegmentStart != nil {
            draftPreviewLabelRoot?.isEnabled = false
            lastPreviewReadoutString = ""
            DispatchQueue.main.async {
                self.measurementReadout = "—"
                self.markCount = 1
            }
            return
        }

        guard let last = committedSegments.last, last.lengthMeters > 1e-5 else {
            draftPreviewLabelRoot?.isEnabled = false
            lineMidHoverDotEntity?.isEnabled = false
            DispatchQueue.main.async {
                self.measurementReadout = "—"
                self.markCount = 2
            }
            return
        }

        draftPreviewLabelRoot?.isEnabled = false
        DispatchQueue.main.async {
            self.measurementReadout = MeasurementUnit.formatDistance(meters: last.lengthMeters, unit: unit)
            self.markCount = 2
        }
    }
}
