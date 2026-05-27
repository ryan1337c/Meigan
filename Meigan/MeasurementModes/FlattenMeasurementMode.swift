import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import OSLog
import Accelerate
import CoreImage
typealias __LAPACK_int = Int32

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

        DispatchQueue.main.async { [weak self, weak host, weak arView] in
            guard let self, let host, let arView else { return }

            host.suppressPlacementBannerChromeDuringFlattenPipelineHandoff()

            host.beginFlattenScanSnapshotDecorations()
            host.applyFlattenScanPreviewSnapshotVisibility()
            arView.snapshot(saveToHDR: false) { previewFull in
                DispatchQueue.main.async { [weak self, weak host, weak arView, previewFull] in
                    guard let host else { return }
                    guard let self, let arView else {
                        host.flattenScanOccludesPlacementChrome = false
                        host.restoreFlattenScanSnapshotDecorations()
                        return
                    }
                    host.applyFlattenScanRawSnapshotVisibility()
                    arView.snapshot(saveToHDR: false) { rawFull in
                        DispatchQueue.main.async { [weak self, weak host, weak arView, previewFull] in
                            guard let host else { return }
                            host.restoreFlattenScanSnapshotDecorations()
                            guard let self, let arView else {
                                host.flattenScanOccludesPlacementChrome = false
                                return
                            }
                            guard let previewFull, let rawFull else {
                                host.flattenScanOccludesPlacementChrome = false
                                host.showPlacementWarning("Scan cancelled. Could not capture the AR view.", kind: .alert)
                                return
                            }
                            let currentPoints = Array(self.flattenPlacedPoints().prefix(4))
                            guard Self.pointsMatch(points, currentPoints),
                                  self.allPointsVisible(currentPoints, in: arView)
                            else {
                                host.flattenScanOccludesPlacementChrome = false
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

    // MARK: - Flatten geometry helpers

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

    private enum FlattenScanOutcome {
        case success
        case failure(String)
    }

    private struct FlattenScanQuality {
        private enum Thresholds {
            /// Reject very small selections where corner noise dominates the geometry.
            static let minimumPrimarySigma: Float = 0.03
            /// Reject if any neighboring corner pair is effectively clustered together.
            static let minimumEdgeLengthMeters: Float = 0.02
            /// A flat quad should have very little variance along the third singular axis.
            static let maximumPlanarityRatio: Float = 0.08
            /// A usable quad needs real spread along two axes, not just one line.
            static let minimumCollinearityRatio: Float = 0.08
        }

        /// Evaluates the completed quad using the SVD-based plane analysis and world-space corners.
        static func evaluate(analysis: FlattenScanAnalysis, points: [SIMD3<Float>]) -> FlattenScanOutcome {
            let sigmas = analysis.singularValues
            guard sigmas.count == 3, points.count == 4, analysis.points2D.count == 4 else {
                return .failure("Scan failed. Complete all 4 corners and try again.")
            }

            let primary = sigmas[0]
            let secondary = sigmas[1]
            let tertiary = sigmas[2]

            // Guards against points that are too close together, too collinear, or not planar enough 
            guard primary >= Thresholds.minimumPrimarySigma else {
                return .failure("Scan failed. The selected corners are too close together.")
            }

            if minimumNeighborDistance(points) < Thresholds.minimumEdgeLengthMeters {
                return .failure("Scan failed. Move corners farther apart, then scan again.")
            }

            guard secondary / primary >= Thresholds.minimumCollinearityRatio else {
                return .failure("Scan failed. The selected corners are too close to a straight line.")
            }

            guard tertiary / primary <= Thresholds.maximumPlanarityRatio else {
                return .failure("Scan failed. The selected corners are not planar enough.")
            }

            guard isConvex(analysis.points2D) else {
                return .failure("Scan failed. The 4 corners must form a convex quad (no bow-tie overlap).")
            }

            guard analysis.imagePlanePoints.count == 4,
                  analysis.destinationCanvasCorners.count == 4,
                  analysis.imageToCanvasHomography != nil,
                  analysis.physicalSizeMeters.x > 0,
                  analysis.physicalSizeMeters.y > 0,
                  analysis.pixelsPerMeter > 0
            else {
                return .failure("Scan failed. Could not map corners to the scan canvas.")
            }

            return .success
        }

        private static func minimumNeighborDistance(_ points: [SIMD3<Float>]) -> Float {
            guard points.count > 1 else { return 0 }
            var minimum = Float.greatestFiniteMagnitude
            for index in points.indices {
                let nextIndex = points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)
                minimum = min(minimum, simd_distance(points[index], points[nextIndex]))
            }
            return minimum
        }

        /// Operates on the in-plane 2D coordinates produced by `scanAnalysis` so the
        /// same projection can be reused later (e.g. homography to image pixels).
        private static func isConvex(_ projected: [SIMD2<Float>]) -> Bool {
            guard projected.count == 4 else { return false }
            let epsilon: Float = 1e-6

            // Bow-tie / self-intersection rejection.
            if segmentsIntersect(projected[0], projected[1], projected[2], projected[3], epsilon: epsilon) {
                return false
            }
            if segmentsIntersect(projected[1], projected[2], projected[3], projected[0], epsilon: epsilon) {
                return false
            }

            // Convexity: all consecutive turns must keep the same sign.
            var turnSign: Float = 0
            for index in projected.indices {
                let a = projected[index]
                let b = projected[(index + 1) % projected.count]
                let c = projected[(index + 2) % projected.count]
                let turn = crossZ(a, b, c)
                if abs(turn) <= epsilon { return false }
                if turnSign == 0 {
                    turnSign = turn
                } else if turnSign * turn < 0 {
                    return false
                }
            }
            return true
        }

        private static func crossZ(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let ab = b - a
            let ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }

        private static func segmentsIntersect(
            _ p1: SIMD2<Float>,
            _ q1: SIMD2<Float>,
            _ p2: SIMD2<Float>,
            _ q2: SIMD2<Float>,
            epsilon: Float
        ) -> Bool {
            let o1 = crossZ(p1, q1, p2)
            let o2 = crossZ(p1, q1, q2)
            let o3 = crossZ(p2, q2, p1)
            let o4 = crossZ(p2, q2, q1)

            if abs(o1) <= epsilon, onSegment(p1, p2, q1, epsilon: epsilon) { return true }
            if abs(o2) <= epsilon, onSegment(p1, q2, q1, epsilon: epsilon) { return true }
            if abs(o3) <= epsilon, onSegment(p2, p1, q2, epsilon: epsilon) { return true }
            if abs(o4) <= epsilon, onSegment(p2, q1, q2, epsilon: epsilon) { return true }

            return (o1 > 0 && o2 < 0 || o1 < 0 && o2 > 0) &&
                   (o3 > 0 && o4 < 0 || o3 < 0 && o4 > 0)
        }

        private static func onSegment(
            _ start: SIMD2<Float>,
            _ point: SIMD2<Float>,
            _ end: SIMD2<Float>,
            epsilon: Float
        ) -> Bool {
            point.x <= max(start.x, end.x) + epsilon &&
            point.x >= min(start.x, end.x) - epsilon &&
            point.y <= max(start.y, end.y) + epsilon &&
            point.y >= min(start.y, end.y) - epsilon
        }
    }

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

    private func flattenPlacedPoints() -> [SIMD3<Float>] {
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

    private static func croppedScanImage(
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

    private static func projectToImagePlane(_ points: [SIMD3<Float>], in arView: ARView) -> [SIMD2<Float>] {
        guard !points.isEmpty,
              let frame = arView.session.currentFrame,
              arView.bounds.width > 0,
              arView.bounds.height > 0
        else {
            return []
        }

        let orientation = interfaceOrientation(in: arView)
        let viewportSize = arView.bounds.size
        return projectToImagePlane(points, frame: frame, orientation: orientation, viewportSize: viewportSize)
    }

    private static func projectToImagePlane(
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

    private static func interfaceOrientation(in arView: ARView) -> UIInterfaceOrientation {
        if let orientation = arView.window?.windowScene?.interfaceOrientation {
            return orientation
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait
    }

    private static func scanCanvasSize(in arView: ARView, footerHeight: CGFloat) -> CGSize {
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

    private static func inverseWarpQuadImage(
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

    private static func renderedPixelsPerMeter(
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

    /// Output of the PCA / SVD-style analysis used by every flatten scan.
    ///
    /// The eigendecomposition of the centered-corner covariance matrix yields singular
    /// values and an orthonormal basis whose third axis is the plane normal. `points2D`
    /// is the projection of the original corners onto `(basisU, basisV)` and is reused
    /// downstream for guards and future homography work.
    struct FlattenScanAnalysis {
        let centroid: SIMD3<Float>
        let basisU: SIMD3<Float>
        let basisV: SIMD3<Float>
        let normal: SIMD3<Float>
        /// sqrt of covariance eigenvalues, sorted descending: σ_U, σ_V, σ_N.
        let singularValues: [Float]
        /// Input corners projected onto `(basisU, basisV)` after subtracting `centroid`.
        let points2D: [SIMD2<Float>]
        /// Input corners projected into the current frame's camera image plane.
        let imagePlanePoints: [SIMD2<Float>]
        /// Destination rect corners on the output canvas (top-left, top-right, bottom-right, bottom-left).
        let destinationCanvasCorners: [SIMD2<Float>]
        /// Output canvas dimensions (full width, height minus footer reservation).
        let outputCanvasSize: SIMD2<Float>
        /// Homography mapping image-plane points into destination canvas coordinates.
        let imageToCanvasHomography: simd_float3x3?
        /// Physical dimensions of the fitted flatten output, in meters.
        let physicalSizeMeters: SIMD2<Float>
        /// Destination rectangle within the output canvas, preserving physical aspect ratio.
        let fittedCanvasRect: CGRect
        /// Uniform pixel density for the flattened output.
        let pixelsPerMeter: Float
        /// Pixel density in the user's selected scale unit.
        let pixelsPerDisplayUnit: Float
        /// User scale units represented by each output pixel.
        let displayUnitsPerPixel: Float
        /// Unit label for scale metadata, e.g. "cm" or "in".
        let displayUnitLabel: String
    }

    static func scanAnalysis(
        for points: [SIMD3<Float>],
        imagePlanePoints: [SIMD2<Float>] = [],
        outputCanvasSize: CGSize? = nil,
        measurementUnit: MeasurementUnit = .metric
    ) -> FlattenScanAnalysis {
        let canvasSize = outputCanvasSize ?? UIScreen.main.bounds.size
        let clampedCanvasSize = SIMD2<Float>(Float(max(1, canvasSize.width)), Float(max(1, canvasSize.height)))
        let fullCanvasRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(clampedCanvasSize.x),
            height: CGFloat(clampedCanvasSize.y)
        )
        let fallbackDestinationCorners = destinationCorners(for: fullCanvasRect)

        guard !points.isEmpty else {
            return FlattenScanAnalysis(
                centroid: SIMD3<Float>(repeating: 0),
                basisU: SIMD3<Float>(1, 0, 0),
                basisV: SIMD3<Float>(0, 1, 0),
                normal: SIMD3<Float>(0, 0, 1),
                singularValues: [0, 0, 0],
                points2D: [],
                imagePlanePoints: imagePlanePoints,
                destinationCanvasCorners: fallbackDestinationCorners,
                outputCanvasSize: clampedCanvasSize,
                imageToCanvasHomography: nil,
                physicalSizeMeters: SIMD2<Float>(repeating: 0),
                fittedCanvasRect: fullCanvasRect,
                pixelsPerMeter: 0,
                pixelsPerDisplayUnit: 0,
                displayUnitsPerPixel: 0,
                displayUnitLabel: measurementUnit.flattenScaleUnitLabel
            )
        }

        let count = Float(points.count)
        let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / count
        var covariance = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)

        for point in points {
            let centered = point - centroid
            let v = [Double(centered.x), Double(centered.y), Double(centered.z)]
            for row in 0..<3 {
                for col in 0..<3 {
                    covariance[row][col] += v[row] * v[col]
                }
            }
        }

        let (eigenvalues, eigenvectors) = eigenDecompositionSymmetric3(covariance)
        // dsyev returns eigenvalues in ascending order — reorder so index 0 is the dominant axis.
        let order = [2, 1, 0]
        let sortedValues = order.map { eigenvalues[$0] }
        let sortedVectors = order.map { eigenvectors[$0] }

        let sigmas = sortedValues.map { Float(sqrt(max($0, 0))) }
        let basisU = vectorFromColumn(sortedVectors[0])
        let basisV = vectorFromColumn(sortedVectors[1])
        let normal = vectorFromColumn(sortedVectors[2])

        let points2D = points.map { point -> SIMD2<Float> in
            let centered = point - centroid
            return SIMD2<Float>(simd_dot(centered, basisU), simd_dot(centered, basisV))
        }

        let orderedIndices = imagePlanePoints.count == points.count
            ? (orderedQuadIndices(imagePlanePoints) ?? orderedQuadIndices(points2D) ?? Array(points.indices))
            : (orderedQuadIndices(points2D) ?? Array(points.indices))
        let orderedWorldPoints = orderedIndices.map { points[$0] }
        let orderedImagePlanePoints = imagePlanePoints.count == points.count
            ? orderedIndices.map { imagePlanePoints[$0] }
            : imagePlanePoints
        let physicalSizeMeters = physicalSizeMeters(for: orderedWorldPoints)
        let fittedCanvasRect = fittedCanvasRect(
            canvasSize: clampedCanvasSize,
            physicalSizeMeters: physicalSizeMeters
        )
        let destinationCorners = destinationCorners(for: fittedCanvasRect)
        let homography = computeHomography(from: orderedImagePlanePoints, to: destinationCorners)
        let pixelsPerMeter = pixelsPerMeter(
            fittedCanvasRect: fittedCanvasRect,
            physicalSizeMeters: physicalSizeMeters
        )
        let pixelsPerDisplayUnit = pixelsPerMeter * measurementUnit.metersPerFlattenScaleUnit
        let displayUnitsPerPixel = pixelsPerDisplayUnit > 0 ? 1 / pixelsPerDisplayUnit : 0

        return FlattenScanAnalysis(
            centroid: centroid,
            basisU: basisU,
            basisV: basisV,
            normal: normal,
            singularValues: sigmas,
            points2D: points2D,
            imagePlanePoints: orderedImagePlanePoints,
            destinationCanvasCorners: destinationCorners,
            outputCanvasSize: clampedCanvasSize,
            imageToCanvasHomography: homography,
            physicalSizeMeters: physicalSizeMeters,
            fittedCanvasRect: fittedCanvasRect,
            pixelsPerMeter: pixelsPerMeter,
            pixelsPerDisplayUnit: pixelsPerDisplayUnit,
            displayUnitsPerPixel: displayUnitsPerPixel,
            displayUnitLabel: measurementUnit.flattenScaleUnitLabel
        )
    }

    private static func destinationCorners(for rect: CGRect) -> [SIMD2<Float>] {
        let minX = Float(rect.minX)
        let minY = Float(rect.minY)
        let maxX = Float(rect.maxX)
        let maxY = Float(rect.maxY)
        return [
            SIMD2<Float>(minX, minY),
            SIMD2<Float>(maxX, minY),
            SIMD2<Float>(maxX, maxY),
            SIMD2<Float>(minX, maxY)
        ]
    }

    private static func physicalSizeMeters(for orderedWorldPoints: [SIMD3<Float>]) -> SIMD2<Float> {
        guard orderedWorldPoints.count == 4 else { return SIMD2<Float>(repeating: 0) }
        let topWidth = simd_distance(orderedWorldPoints[0], orderedWorldPoints[1])
        let bottomWidth = simd_distance(orderedWorldPoints[3], orderedWorldPoints[2])
        let leftHeight = simd_distance(orderedWorldPoints[0], orderedWorldPoints[3])
        let rightHeight = simd_distance(orderedWorldPoints[1], orderedWorldPoints[2])
        return SIMD2<Float>(
            (topWidth + bottomWidth) * 0.5,
            (leftHeight + rightHeight) * 0.5
        )
    }

    private static func fittedCanvasRect(
        canvasSize: SIMD2<Float>,
        physicalSizeMeters: SIMD2<Float>
    ) -> CGRect {
        let availableWidth = CGFloat(max(1, canvasSize.x))
        let availableHeight = CGFloat(max(1, canvasSize.y))
        let widthMeters = CGFloat(physicalSizeMeters.x)
        let heightMeters = CGFloat(physicalSizeMeters.y)
        guard widthMeters > 1e-5, heightMeters > 1e-5 else {
            return CGRect(x: 0, y: 0, width: availableWidth, height: availableHeight)
        }

        let physicalAspect = widthMeters / heightMeters
        let availableAspect = availableWidth / availableHeight
        let fittedWidth: CGFloat
        let fittedHeight: CGFloat
        if availableAspect > physicalAspect {
            fittedHeight = availableHeight
            fittedWidth = fittedHeight * physicalAspect
        } else {
            fittedWidth = availableWidth
            fittedHeight = fittedWidth / physicalAspect
        }

        return CGRect(
            x: (availableWidth - fittedWidth) * 0.5,
            y: (availableHeight - fittedHeight) * 0.5,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private static func pixelsPerMeter(
        fittedCanvasRect: CGRect,
        physicalSizeMeters: SIMD2<Float>
    ) -> Float {
        guard physicalSizeMeters.x > 1e-5, physicalSizeMeters.y > 1e-5 else { return 0 }
        let horizontal = Float(fittedCanvasRect.width) / physicalSizeMeters.x
        let vertical = Float(fittedCanvasRect.height) / physicalSizeMeters.y
        return min(horizontal, vertical)
    }

    private static func computeHomography(from source: [SIMD2<Float>], to destination: [SIMD2<Float>]) -> simd_float3x3? {
        guard source.count == 4, destination.count == 4 else { return nil }
        let src = source
        let dst = destination

        var coefficients = [[Double]]()
        var constants = [Double]()
        coefficients.reserveCapacity(8)
        constants.reserveCapacity(8)

        for i in 0..<4 {
            let x = Double(src[i].x)
            let y = Double(src[i].y)
            let u = Double(dst[i].x)
            let v = Double(dst[i].y)
            coefficients.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
            constants.append(u)
            coefficients.append([0, 0, 0, x, y, 1, -v * x, -v * y])
            constants.append(v)
        }

        guard let h = solveLinearSystem(coefficients, constants) else { return nil }

        return simd_float3x3(
            SIMD3<Float>(Float(h[0]), Float(h[1]), Float(h[2])),
            SIMD3<Float>(Float(h[3]), Float(h[4]), Float(h[5])),
            SIMD3<Float>(Float(h[6]), Float(h[7]), 1)
        )
    }

    private static func solveLinearSystem(_ coefficients: [[Double]], _ constants: [Double]) -> [Double]? {
        let count = constants.count
        guard coefficients.count == count,
              coefficients.allSatisfy({ $0.count == count })
        else { return nil }

        var augmented = zip(coefficients, constants).map { row, constant in
            row + [constant]
        }

        for column in 0..<count {
            guard let pivotRow = (column..<count).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }),
            abs(augmented[pivotRow][column]) > 1e-10
            else {
                return nil
            }

            if pivotRow != column {
                augmented.swapAt(pivotRow, column)
            }

            let pivot = augmented[column][column]
            for valueIndex in column...count {
                augmented[column][valueIndex] /= pivot
            }

            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                guard abs(factor) > 1e-14 else { continue }
                for valueIndex in column...count {
                    augmented[row][valueIndex] -= factor * augmented[column][valueIndex]
                }
            }
        }

        return augmented.map { $0[count] }
    }

    private static func orderedQuadIndices(_ points: [SIMD2<Float>]) -> [Int]? {
        guard points.count == 4 else { return nil }
        let sum = points.map { $0.x + $0.y }
        let diff = points.map { $0.x - $0.y }

        let topLeft = sum.indices.min(by: { sum[$0] < sum[$1] }) ?? 0
        let bottomRight = sum.indices.max(by: { sum[$0] < sum[$1] }) ?? 0
        let topRight = diff.indices.max(by: { diff[$0] < diff[$1] }) ?? 0
        let bottomLeft = diff.indices.min(by: { diff[$0] < diff[$1] }) ?? 0
        let indices = [topLeft, topRight, bottomRight, bottomLeft]
        guard Set(indices).count == 4 else { return nil }

        return indices
    }

    private static func vectorFromColumn(_ column: [Double]) -> SIMD3<Float> {
        SIMD3<Float>(Float(column[0]), Float(column[1]), Float(column[2]))
    }

    /// LAPACK-backed symmetric eigendecomposition (eigenvalues + eigenvectors), used as the SVD of the centered covariance.
    private static func eigenDecompositionSymmetric3(_ matrix: [[Double]]) -> (eigenvalues: [Double], eigenvectors: [[Double]]) {
        // Flatten to column-major format for LAPACK
        var a = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                a[j * 3 + i] = matrix[i][j]  // Column-major
            }
        }

        var n = __LAPACK_int(3)
        var lda = __LAPACK_int(3)
        var w = [Double](repeating: 0, count: 3)  // Eigenvalues output (ascending)
        var lwork = __LAPACK_int(-1)
        var work = [Double](repeating: 0, count: 1)
        var info = __LAPACK_int(0)
        var jobz = Int8(86)  // 'V' = eigenvalues + eigenvectors
        var uplo = Int8(85)  // 'U' = upper triangle

        // Query optimal work size
        dsyev_(&jobz, &uplo, &n, &a, &lda, &w, &work, &lwork, &info)

        lwork = __LAPACK_int(work[0])
        work = [Double](repeating: 0, count: Int(lwork))

        // Compute eigenvalues + eigenvectors. After this, `a` holds the orthonormal
        // eigenvectors as columns (column-major), one per eigenvalue in `w`.
        dsyev_(&jobz, &uplo, &n, &a, &lda, &w, &work, &lwork, &info)

        var eigenvectors: [[Double]] = []
        eigenvectors.reserveCapacity(3)
        for k in 0..<3 {
            eigenvectors.append([a[k * 3 + 0], a[k * 3 + 1], a[k * 3 + 2]])
        }
        return (w, eigenvectors)
    }

    // MARK: - Flatten previews (draft polyline + fill polygon)

    /// Draws a dynamic translucent polygon while aiming the 3rd or 4th corner in flatten mode.
    /// - 3rd corner aim (1 committed segment + draft): triangle [P1, P2, hover]
    /// - 4th corner aim (2 committed segments + draft): quad [P1, P2, P3, hover]
    private func updateFlattenFillPreview(hoverWorld: SIMD3<Float>) {
        guard let host, let container = host.flattenFillPreviewContainer else { return }

        if let adjustingIndex = host.flattenAdjustingPointIndex {
            var points = flattenPlacedPoints()
            guard points.indices.contains(adjustingIndex), points.count >= 3 else {
                if !container.children.isEmpty {
                    host.clearEntityChildren(container)
                }
                container.isEnabled = false
                return
            }
            points[adjustingIndex] = hoverWorld
            guard let entity = makeFlattenFillEntity(points: points) else {
                if !container.children.isEmpty {
                    host.clearEntityChildren(container)
                }
                container.isEnabled = false
                return
            }

            host.clearEntityChildren(container)
            container.addChild(entity)
            container.isEnabled = true
            return
        }

        guard host.draftSegmentStart != nil else {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        let segCount = host.committedSegments.count
        guard segCount == 1 || segCount == 2 else {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        var points: [SIMD3<Float>] = []
        points.append(host.committedSegments[0].start)
        points.append(host.committedSegments[0].end)
        if segCount == 2 {
            points.append(host.committedSegments[1].end)
        }
        points.append(hoverWorld)

        // Skip degenerate polygons (repeated / near-collinear last point).
        if simd_distance(points[points.count - 2], points[points.count - 1]) < 1e-4 {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        // Hide preview if P4 is inside triangle P1-P2-P3
        if points.count == 4 && isPointInsideTriangle(points[3], points[0], points[1], points[2]) {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        guard let entity = makeFlattenFillEntity(points: points) else {
            if !container.children.isEmpty {
                host.clearEntityChildren(container)
            }
            container.isEnabled = false
            return
        }

        host.clearEntityChildren(container)
        container.addChild(entity)
        container.isEnabled = true
    }

    private func updateFlattenDraftPreview(reticleWorld: SIMD3<Float>) {
        guard let host, let lineContainer = host.previewLinesContainer else { return }

        host.draftPreviewLabelRoot?.isEnabled = false
        host.lastPreviewReadoutString = ""
        host.clearEntityChildren(lineContainer)

        if let adjustingIndex = host.flattenAdjustingPointIndex {
            let points = flattenPlacedPoints()
            guard points.indices.contains(adjustingIndex) else {
                lineContainer.isEnabled = false
                return
            }

            if adjustingIndex > 0 {
                host.addDottedLine(from: points[adjustingIndex - 1], to: reticleWorld, in: lineContainer)
            }
            if adjustingIndex + 1 < points.count {
                host.addDottedLine(from: points[adjustingIndex + 1], to: reticleWorld, in: lineContainer)
            }
            if points.count == 4, adjustingIndex == 3 {
                let edge = closestBaseTriangleEdge(to: reticleWorld, p1: points[0], p2: points[1], p3: points[2])
                host.clearEntityChildren(lineContainer)
                host.addDottedLine(from: edge.0, to: reticleWorld, in: lineContainer)
                host.addDottedLine(from: edge.1, to: reticleWorld, in: lineContainer)
            }
            lineContainer.isEnabled = !lineContainer.children.isEmpty
            return
        }

        guard host.draftSegmentStart != nil else {
            lineContainer.isEnabled = false
            return
        }

        switch host.committedSegments.count {
        case 0:
            guard let start = host.draftSegmentStart else {
                lineContainer.isEnabled = false
                return
            }
            host.addDottedLine(from: start, to: reticleWorld, in: lineContainer)

        case 1:
            host.addDottedLine(from: host.committedSegments[0].end, to: reticleWorld, in: lineContainer)

        case 2:
            let p1 = host.committedSegments[0].start
            let p2 = host.committedSegments[0].end
            let p3 = host.committedSegments[1].end
            let edge = closestBaseTriangleEdge(to: reticleWorld, p1: p1, p2: p2, p3: p3)
            host.addDottedLine(from: edge.0, to: reticleWorld, in: lineContainer)
            host.addDottedLine(from: edge.1, to: reticleWorld, in: lineContainer)

        default:
            lineContainer.isEnabled = false
            return
        }

        lineContainer.isEnabled = !lineContainer.children.isEmpty
    }

    private func closestBaseTriangleEdge(
        to point: SIMD3<Float>,
        p1: SIMD3<Float>,
        p2: SIMD3<Float>,
        p3: SIMD3<Float>
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let distToEdge12 = distanceFromPointToSegment3D(point, p1, p2)
        let distToEdge23 = distanceFromPointToSegment3D(point, p2, p3)
        let distToEdge31 = distanceFromPointToSegment3D(point, p3, p1)

        if distToEdge12 <= distToEdge23 && distToEdge12 <= distToEdge31 {
            return (p1, p2)
        }
        if distToEdge23 <= distToEdge31 {
            return (p2, p3)
        }
        return (p3, p1)
    }

    /// Builds a double-sided triangle-fan mesh over `points` (>= 3) with a translucent teal material.
    private func makeFlattenFillEntity(points: [SIMD3<Float>]) -> ModelEntity? {
        guard points.count >= 3 else { return nil }

        var descriptor = MeshDescriptor(name: "FlattenFillPreview")

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Front-facing triangles
        for p in points { positions.append(p) }

        if points.count == 3 {
            // Simple triangle
            indices.append(contentsOf: [0, 1, 2])
        } else if points.count == 4 {
            // Keep the base triangle (P1-P2-P3) and add one extra triangle from P4
            // to whichever edge of the base triangle is closest.
            indices.append(contentsOf: [0, 1, 2])

            // Find which edge of triangle P1-P2-P3 is closest to P4
            let p1 = points[0], p2 = points[1], p3 = points[2], p4 = points[3]

            let distToEdge12 = distanceFromPointToSegment3D(p4, p1, p2)
            let distToEdge23 = distanceFromPointToSegment3D(p4, p2, p3)
            let distToEdge31 = distanceFromPointToSegment3D(p4, p3, p1)

            if distToEdge12 <= distToEdge23 && distToEdge12 <= distToEdge31 {
                // Closest to P1-P2: connect P4 to that edge
                // Triangles: [P1,P2,P4]
                indices.append(contentsOf: [0, 1, 3])
            } else if distToEdge23 <= distToEdge31 {
                // Closest to P2-P3: connect P4 to that edge
                // Triangles: [P2,P3,P4]
                indices.append(contentsOf: [1, 2, 3])
            } else {
                // Closest to P3-P1: connect P4 to that edge
                // Triangles: [P3,P1,P4]
                indices.append(contentsOf: [2, 0, 3])
            }
        }

        // Back-facing triangles (duplicated verts, reversed winding for double-sided visibility)
        let backOffset = UInt32(positions.count)
        for p in points { positions.append(p) }

        if points.count == 3 {
            indices.append(contentsOf: [backOffset + 0, backOffset + 2, backOffset + 1])
        } else if points.count == 4 {
            // Back face for base triangle (reverse winding)
            indices.append(contentsOf: [backOffset + 0, backOffset + 2, backOffset + 1])

            let p1 = points[0], p2 = points[1], p3 = points[2], p4 = points[3]

            let distToEdge12 = distanceFromPointToSegment3D(p4, p1, p2)
            let distToEdge23 = distanceFromPointToSegment3D(p4, p2, p3)
            let distToEdge31 = distanceFromPointToSegment3D(p4, p3, p1)

            if distToEdge12 <= distToEdge23 && distToEdge12 <= distToEdge31 {
                indices.append(contentsOf: [backOffset + 0, backOffset + 3, backOffset + 1])

            } else if distToEdge23 <= distToEdge31 {
                indices.append(contentsOf: [backOffset + 1, backOffset + 3, backOffset + 2])

            } else {
                indices.append(contentsOf: [backOffset + 2, backOffset + 3, backOffset + 0])

            }
        }

        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            var material = UnlitMaterial()
            material.color = .init(tint: .systemTeal)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.3))
            return ModelEntity(mesh: mesh, materials: [material])
        } catch {
            arPlacementLog.warning("makeFlattenFillEntity: mesh generation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // Calculate 3D distance from point to line segment
    private func distanceFromPointToSegment3D(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let ap = p - a
        let ab2 = simd_length_squared(ab)

        if ab2 < 1e-8 {
            return simd_distance(p, a)
        }

        var t = simd_dot(ap, ab) / ab2
        t = min(max(t, 0), 1)  // Clamp to [0, 1] for segment
        let closest = a + t * ab
        return simd_distance(p, closest)
    }

    // Test if point is inside triangle using barycentric coordinates (projected to XZ plane)
    private func isPointInsideTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
        // 2D cross product helper (projects to horizontal XZ plane)
        func sign(_ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) -> Float {
            return (p1.x - p3.x) * (p2.z - p3.z) - (p2.x - p3.x) * (p1.z - p3.z)
        }

        let d1 = sign(p, a, b)
        let d2 = sign(p, b, c)
        let d3 = sign(p, c, a)

        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)

        // Point is inside if all signs are the same (all positive or all negative)
        return !(hasNeg && hasPos)
    }
}
