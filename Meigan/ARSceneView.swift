import SwiftUI
import RealityKit
import ARKit
import Combine
import UIKit
import OSLog

/// Debug placement / token sync; filter Console by subsystem or category `ARPlacement`.
private let arPlacementLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

// MARK: - Line extension (reticle autolock to segment pinpoints)

/// When a measurement line exists, the reticle can snap to: first mark (left), second mark (right), or segment midpoint — whichever projects closest to the crosshair within `screenSnapRadiusPoints`.
private enum LineExtensionReticleConfig {
    static let screenSnapRadiusPoints: CGFloat = 38
    /// Crosshair this close (points) to the 2D segment between the two marks counts as “on the line”.
    static let lineHoverScreenDistancePoints: CGFloat = 28
}

// MARK: - Measurement readout (compact black text + white bordered pill)

private enum MeasurementLabelStyle {
    /// Slightly larger than text layout so the pill reads as a border around the readout.
    static let pillWidth: Float = 0.084
    static let pillHeight: Float = 0.028
    static let textFrame = CGRect(x: 0, y: 0, width: 0.074, height: 0.02)
    static let fontMeters: CGFloat = 0.016
    /// Prefer Helvetica (stable PostScript name) for extruded text; fall back to SF UI if needed.
    private static let meshFontPostScriptCandidates = ["Helvetica", ".SFUI-Regular"]
    /// Shift readout slightly toward the camera so it sorts in front of the dashed line (avoids z‑fight / line cutting the pill).
    static let labelTowardCameraBiasMeters: Float = 0.007

    /// Font for `MeshResource.generateText` — PostScript names only (avoids CoreText display-name notes).
    static func meshFontForGenerateText() -> MeshResource.Font {
        for psName in meshFontPostScriptCandidates {
            if let font = MeshResource.Font(name: psName, size: fontMeters) {
                return font
            }
        }
        return MeshResource.Font.systemFont(ofSize: fontMeters)
    }

    /// Strips characters that tend to pull in fallback fonts during `generateText` shaping.
    /// `fileprivate` so `Coordinator` call sites in this file can use it (`private` would limit access to this enum only).
    fileprivate static func meshDisplayText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
    }
    /// At this camera–label distance, world scale is 1.0 (matches previous “natural” size at arm’s length).
    static let labelReferenceCameraDistanceMeters: Float = 0.65
    static let labelDistanceScaleMin: Float = 0.3
    static let labelDistanceScaleMax: Float = 12.0

    static func borderedPillMaterial() -> UnlitMaterial {
        let pixW = 384
        let ratio = CGFloat(pillHeight / pillWidth)
        let pixH = max(64, Int(CGFloat(pixW) * ratio))
        let w = CGFloat(pixW)
        let h = CGFloat(pixH)
        let format = UIGraphicsImageRendererFormat()
        // Transparent outside the pill so the plane isn’t a white rectangle with a rounded stroke inside it.
        format.opaque = false
        format.scale = 2.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let borderWidth: CGFloat = 2.25
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.cgContext.clear(rect)

            // Tiny inset from texture edge for anti-aliasing.
            let outer = rect.insetBy(dx: 1.0, dy: 1.0)
            let outerR = min(outer.width, outer.height) * 0.5
            let outerPath = UIBezierPath(roundedRect: outer, cornerRadius: outerR)

            // Border = gray “ring”; fill = white inner capsule (same shape, inset).
            UIColor(white: 0.82, alpha: 1).setFill()
            outerPath.fill()

            let inner = outer.insetBy(dx: borderWidth, dy: borderWidth)
            guard inner.width > 2, inner.height > 2 else { return }
            let innerR = min(inner.width, inner.height) * 0.5
            let innerPath = UIBezierPath(roundedRect: inner, cornerRadius: innerR)
            UIColor.white.setFill()
            innerPath.fill()
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource.generate(
                  from: cgImage,
                  options: TextureResource.CreateOptions(semantic: .color)
              )
        else {
            var m = UnlitMaterial()
            m.color = .init(tint: .white)
            return m
        }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        // Required so alpha outside the rounded pill shows as clear (not black / opaque quad).
        m.blending = .transparent(opacity: 1.0)
        return m
    }
}

struct ARSceneView: UIViewRepresentable {
    @Binding var isCoachingActive: Bool
    @Binding var isRelocalizing: Bool
    @Binding var hasValidTarget: Bool
    @Binding var measurementReadout: String
    @Binding var markCount: Int
    @Binding var flattenSegmentCount: Int
    @Binding var measurementModeRaw: String
    @Binding var measurementUnitRaw: String
    @Binding var placeMarkToken: Int
    @Binding var clearMarksToken: Int
    @Binding var screenshotToken: Int
    @Binding var screenshotPreviewImage: UIImage?
    @Binding var flattenScanToken: Int
    @Binding var flattenScanPreviewImage: UIImage?
    @Binding var flattenScanResultImage: UIImage?
    @Binding var flattenShapeFindings: [FlattenShapeFinding]
    @Binding var flattenDetectionPreviewImage: UIImage?
    @Binding var isFlattenScanActive: Bool
    @Binding var flattenScanSigmas: [Float]
    @Binding var flattenScanCornersReady: Bool
    @Binding var hapticFeedbackEnabled: Bool
    @Binding var placementWarningMessage: String
    @Binding var placementWarningToken: Int
    @Binding var placementBannerKind: PlacementBannerKind
    @Binding var flattenRelocationActive: Bool
    @Binding var flattenFooterHeight: CGFloat
    /// Consecutive placement-guide frames before showing a placement hint (read on the RealityKit update thread).
    let trackingGuideShowThreshold: Int
    @Binding var activeTrackingReason: ARCamera.TrackingState.Reason?
    @Binding var trackingGuideMessage: String
    @Binding var trackingGuideKind: PlacementBannerKind
    @Binding var identifyDetections: [IdentifyDetection]

    class Coordinator: NSObject, ARCoachingOverlayViewDelegate, ARSessionDelegate {
        @Binding var isCoachingActive: Bool
        @Binding var isRelocalizing: Bool
        weak var arView: ARView?
        weak var coachingOverlay: ARCoachingOverlayView?
        var updateSubscription: Cancellable?
        private var hasCompletedCoachingOnce = false
        @Binding var hasValidTarget: Bool
        @Binding var measurementReadout: String
        @Binding var markCount: Int
        @Binding var flattenSegmentCount: Int
        @Binding var measurementModeRaw: String
        @Binding var measurementUnitRaw: String
        @Binding var screenshotPreviewImage: UIImage?
        @Binding var flattenScanPreviewImage: UIImage?
        @Binding var flattenScanResultImage: UIImage?
        @Binding var flattenShapeFindings: [FlattenShapeFinding]
        @Binding var flattenDetectionPreviewImage: UIImage?
        @Binding var isFlattenScanActive: Bool
        @Binding var flattenScanSigmas: [Float]
        @Binding var flattenScanCornersReady: Bool
        @Binding var hapticFeedbackEnabled: Bool
        @Binding var placementWarningMessage: String
        @Binding var placementWarningToken: Int
        @Binding var placementBannerKind: PlacementBannerKind
        @Binding var flattenRelocationActive: Bool
        var flattenFooterHeight: CGFloat = 0
        @Binding var activeTrackingReason: ARCamera.TrackingState.Reason?
        @Binding var trackingGuideMessage: String
        @Binding var trackingGuideKind: PlacementBannerKind
        @Binding var identifyDetections: [IdentifyDetection]
        
        private var ringAnchor: AnchorEntity?
        private var ringEntity: ModelEntity?

        /// Last smoothed reticle position for placing marks (world space).
        private var latestReticleWorldPosition: SIMD3<Float>?

        // Measurement visuals (world anchor at origin)
        private var measurementAnchor: AnchorEntity?
        /// Solid geometry for all committed edges (never cleared by preview updates).
        private var committedLinesContainer: Entity?
        /// Dotted preview only while placing the free end of the current segment.
        var previewLinesContainer: Entity?
        /// White spheres at deduped joints (committed vertices + draft start).
        private var vertexMarkersContainer: Entity?
        private var markerSphereMesh: MeshResource?
        private var lineDashSegmentMesh: MeshResource?
        /// One billboard stack (pill + text) per committed segment, oldest → newest.
        private var committedSegmentLabelsContainer: Entity?
        /// Preview readout while aiming the free end of the draft segment.
        var draftPreviewLabelRoot: Entity?
        private var draftLabelPillEntity: ModelEntity?
        private var draftLabelTextEntity: ModelEntity?
        /// Shown at segment midpoint while the crosshair is on the line (label hidden for that beat).
        var lineMidHoverDotEntity: ModelEntity?
        /// Finished edges in chronological order (oldest first).
        var committedSegments: [MeasurementSegment] = []
        /// When non-nil, user is aiming the second endpoint of a new segment starting at this world position.
        var draftSegmentStart: SIMD3<Float>?
        /// Translucent triangle (draft of P3) / quad (draft of P4) rendered under the measurement anchor while in flatten mode.
        var flattenFillPreviewContainer: Entity?
        // Comitted fill container for flatten mode
        var committedFillContainer: Entity?
        /// When non-nil, a placed Flatten corner is selected and the next surface tap moves that corner.
        var flattenAdjustingPointIndex: Int?
        /// Mirrored from `ARSceneView.updateUIView` every frame. The coordinator’s `@Binding measurementModeRaw`
        /// is captured only once in `makeCoordinator` and can stay stale vs the parent’s custom `Binding` — use this for mode checks.
        var appliedMeasurementModeRaw: String = ARFooterFeature.ruler.rawValue
        /// Mirrored from the representable each SwiftUI update so the RealityKit update thread never reads `@Binding`s.
        var appliedTrackingGuideShowThreshold: Int = 6

        private var isFlattenMode: Bool {
            appliedMeasurementModeRaw == ARFooterFeature.flatten.rawValue
        }

        private var isIdentifyMode: Bool {
            appliedMeasurementModeRaw == ARFooterFeature.identify.rawValue
        }

        // MARK: - Mode controllers
        //
        // Mode-specific decisions (placement semantics, pin candidates, per-frame previews,
        // line hover) are delegated to a `MeasurementModeBehavior`. `currentMode` resolves
        // the active behavior from `appliedMeasurementModeRaw` so it always reflects the
        // freshest mode value (the `@Binding` itself can be stale — see `appliedMeasurementModeRaw`).
        lazy var rulerMode: RulerMeasurementMode = RulerMeasurementMode(host: self)
        lazy var flattenMode: FlattenMeasurementMode = FlattenMeasurementMode(host: self)
        lazy var identifyMode: IdentifyMeasurementMode = IdentifyMeasurementMode(host: self)
        var currentMode: MeasurementModeBehavior {
            if isFlattenMode { return flattenMode }
            if isIdentifyMode { return identifyMode }
            return rulerMode
        }

        /// Last world position we fired an autolock haptic for (nil = unlocked).
        var lastAutolockedPinWorld: SIMD3<Float>?

        /// While a finished segment exists, the pinpoint world position when the reticle is autolocked (left, right, or mid). Used to extend a new segment from that pin on place.
        var latestPinAutolockWorld: SIMD3<Float>?

        /// Avoids regenerating text meshes / spamming SwiftUI when the preview readout string is unchanged.
        var lastPreviewReadoutString: String = ""

        private var lastProcessedPlaceToken: Int = 0
        private var lastProcessedClearToken: Int = 0
        private var lastProcessedScreenshotToken: Int = 0
        private var lastProcessedFlattenScanToken: Int = 0
        private var lastSyncedMeasurementUnitRaw: String = ""
        private var lastSyncedMeasurementModeRaw: String = ARFooterFeature.ruler.rawValue
        private var lastSyncedFlattenFooterHeight: CGFloat = 0

        // Smoothing state (nil = snap to first hit)
        private var smoothPosition: SIMD3<Float>?
        private var smoothRotation: simd_quatf?
        /// Low-pass filtered surface normal — cuts twist/spin from noisy raycast normals (broken ring makes this visible).
        private var smoothNormal: SIMD3<Float>?
        private var lastUpdateTime: CFTimeInterval = 0

        /// Debounce validity: hide after N consecutive bad frames; show after N consecutive good frames (when hidden).
        private var consecutiveMisses = 0
        private var consecutiveHits = 0
        /// Higher = fewer spurious hides when ARKit drops a few frames on a valid surface (e.g. stationary aim).
        private let missThreshold = 12
        private let showThreshold = 2
        private let normalSmoothAlpha: Float = 0.14
        private let minReticlePlacementDistanceMeters: Float = 0.15

        /// Avoid hiding reticle on single-frame tracking flicker.
        private var consecutiveBadTrackingFrames = 0
        private let badTrackingThreshold = 6

        // Lighting guidance
        private var smoothedAmbientIntensity: CGFloat? // Smooth ambient intensity for lighting guidance
        private let ambientIntensityEMAAlpha: CGFloat = 0.2 // Used for EMA this it our alpha value
        private let tooDarkThreshold: CGFloat = 520 // 200 - 300 for dim rooms 
        private let tooDarkConsecutiveFramesThreshold = 12
        private var tooDarkConsecutiveFrames = 0
        private var isTooDark = false
        private var lightingGuidePromotedIssue: ResolvedTrackingGuideIssue = .none

        private enum PlacementGuideIssue: Equatable {
            case none
            case tooClose
            case findNearbySurface
        }

        private enum ARKitGuideIssue: Equatable {
            case none
            case excessiveMotion
            case findNearbySurface
        }

        private enum ResolvedTrackingGuideIssue: Equatable {
            case none
            case tooClose
            case excessiveMotion
            case findNearbySurface
            case tooDark
        }

        /// Placement guidance debounce state (`startUpdateLoop` / `.normal` path).
        private var placementGuideDebounceIssue: PlacementGuideIssue = .none
        private var placementGuideDebounceFrameCount: Int = 0
        private var placementGuidePromotedIssue: PlacementGuideIssue = .none

        /// ARKit guidance debounce state (`.limited` / `.notAvailable` path).
        private var arKitInsufficientFeaturesFrameCount: Int = 0
        private var arKitNoneFrameCount: Int = 0
        private let arKitInsufficientFeaturesShowThreshold = 8
        private let arKitClearShowThreshold = 1

        private var arKitGuidePromotedIssue: ARKitGuideIssue = .none


        // Custom motion detection (replace ARKit's excessive motion):
        /// Per-frame metric: displacement weight × translation (m) + rotation weight × angular delta (rad).
        private let customExcessiveMotionThreshold: Float = 0.008
        /// Translation (m/frame) multiplied by this for `motionScore`; lower = more lenient on movement.
        private let customExcessiveMotionDisplacementWeight: Float = 0.25
        /// Rotation (rad/frame) multiplied by this and added to translation for `motionScore`; tune on device (~0.05).
        private let customExcessiveMotionRotationWeight: Float = 0.09
        private var lastCameraTransform: simd_float4x4?
        private var customExcessiveMotionFrameCount = 0
        private let customExcessiveMotionShowThreshold = 2
        private var customExcessiveMotionActive = false
        private var customMotionPromotedIssue: ResolvedTrackingGuideIssue = .none // Add new property for custom motion (separate from ARKit's state)

        var flattenScanOccludesPlacementChrome = false

        /// Issue currently shown in the tracking guide banner.
        private var displayedTrackingGuideIssue: ResolvedTrackingGuideIssue = .none
        private var trackingGuideDisplayedAt: Date?
        private static let trackingGuideMinimumDisplayDuration: TimeInterval = 2
        private var trackingGuideTransitionWorkItem: DispatchWorkItem?

        private var lastFlattenScanCornersReady = false

        /// Bumped to drop in-flight flatten scan completion work (e.g. user cancelled while processing).
        var flattenScanInvalidateGeneration: UInt64 = 0

        /// Captured `isEnabled` for flatten dual-snapshot capture (preview vs raw).
        private struct FlattenScanSnapshotDecorationRestore {
            let ring: Bool
            let hasValidTarget: Bool
            let committedLines: Bool
            let committedFill: Bool
            let segmentLabels: Bool
            let draftLabel: Bool
            let flattenFillPreview: Bool
            let previewLines: Bool
            let vertexMarkers: Bool
            let lineMidHoverDot: Bool
        }

        private var flattenScanSnapshotDecorationRestore: FlattenScanSnapshotDecorationRestore?

        /// While true, the per-frame loop must not re-enable the ring between hiding it and `ARView.snapshot` completing.
        private var isFlattenScanSnapshotCaptureActive = false

        init(
            isCoachingActive: Binding<Bool>,
            isRelocalizing: Binding<Bool>,
            hasValidTarget: Binding<Bool>,
            measurementReadout: Binding<String>,
            markCount: Binding<Int>,
            flattenSegmentCount: Binding<Int>,
            measurementModeRaw: Binding<String>,
            measurementUnitRaw: Binding<String>,
            screenshotPreviewImage: Binding<UIImage?>,
            flattenScanPreviewImage: Binding<UIImage?>,
            flattenScanResultImage: Binding<UIImage?>,
            flattenShapeFindings: Binding<[FlattenShapeFinding]>,
            flattenDetectionPreviewImage: Binding<UIImage?>,
            isFlattenScanActive: Binding<Bool>,
            flattenScanSigmas: Binding<[Float]>,
            flattenScanCornersReady: Binding<Bool>,
            hapticFeedbackEnabled: Binding<Bool>,
            placementWarningMessage: Binding<String>,
            placementWarningToken: Binding<Int>,
            placementBannerKind: Binding<PlacementBannerKind>,
            flattenRelocationActive: Binding<Bool>,
            activeTrackingReason: Binding<ARCamera.TrackingState.Reason?>,
            trackingGuideMessage: Binding<String>,
            trackingGuideKind: Binding<PlacementBannerKind>,
            identifyDetections: Binding<[IdentifyDetection]>
        ) {
            _isCoachingActive = isCoachingActive
            _isRelocalizing = isRelocalizing
            _hasValidTarget = hasValidTarget
            _measurementReadout = measurementReadout
            _markCount = markCount
            _flattenSegmentCount = flattenSegmentCount
            _measurementModeRaw = measurementModeRaw
            _measurementUnitRaw = measurementUnitRaw
            _screenshotPreviewImage = screenshotPreviewImage
            _flattenScanPreviewImage = flattenScanPreviewImage
            _flattenScanResultImage = flattenScanResultImage
            _flattenShapeFindings = flattenShapeFindings
            _flattenDetectionPreviewImage = flattenDetectionPreviewImage
            _isFlattenScanActive = isFlattenScanActive
            _flattenScanSigmas = flattenScanSigmas
            _flattenScanCornersReady = flattenScanCornersReady
            _hapticFeedbackEnabled = hapticFeedbackEnabled
            _placementWarningMessage = placementWarningMessage
            _placementWarningToken = placementWarningToken
            _placementBannerKind = placementBannerKind
            _flattenRelocationActive = flattenRelocationActive
            _activeTrackingReason = activeTrackingReason
            _trackingGuideMessage = trackingGuideMessage
            _trackingGuideKind = trackingGuideKind
            _identifyDetections = identifyDetections
        }

        deinit {
            updateSubscription?.cancel()
            cancelTrackingGuideTransition()
        }

        /// Stops the per-frame loop, pauses ARKit, and detaches delegates so navigating away from the
        /// AR view doesn't keep camera capture, plane detection, or scene mesh generation running.
        func teardownSession() {
            updateSubscription?.cancel()
            updateSubscription = nil
            cancelTrackingGuideTransition()
            flattenScanOccludesPlacementChrome = false

            if let arView {
                arView.session.delegate = nil
                arView.session.pause()
            }

            if let overlay = coachingOverlay {
                overlay.delegate = nil
                overlay.session = nil
            }
        }

        // MARK: - Coaching overlay delegate

        func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) {
            isCoachingActive = true
        }

        func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
            isCoachingActive = false
            if !hasCompletedCoachingOnce {
                hasCompletedCoachingOnce = true
                coachingOverlayView.activatesAutomatically = false
            }
        }

        // MARK: - Session delegate

        func sessionWasInterrupted(_ session: ARSession) {
            DispatchQueue.main.async {
                self.isRelocalizing = true
            }
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            let configuration = ARSceneView.makeWorldTrackingConfiguration()
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

            hideRing()
            clearAllMeasurements()

            DispatchQueue.main.async {
                self.isRelocalizing = false
            }
        }

        /// Hide crosshair and clear smoothing so the next valid aim snaps cleanly (no freeze-then-jump).
        private func hideRingForSessionReset() {
            ringEntity?.isEnabled = false
            smoothPosition = nil
            smoothRotation = nil
            smoothNormal = nil
            lastUpdateTime = 0
            consecutiveMisses = 0
            consecutiveHits = 0
            lastAutolockedPinWorld = nil
            latestPinAutolockWorld = nil
        }

        private func hideRing() {
            hideRingForSessionReset()
            if self.draftSegmentStart != nil {
                self.clearSingleMarkPreviewVisuals()
            }
            DispatchQueue.main.async { self.hasValidTarget = false }
        }

        /// `ARRaycastQuery.Target` has no `.mesh` — only plane types. Scene reconstruction in `makeWorldTrackingConfiguration()` still helps LiDAR sessions.
        private func raycastReticle(from center: CGPoint, in arView: ARView) -> ARRaycastResult? {
            if let q = arView.makeRaycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .any),
               let h = arView.session.raycast(q).first {
                return h
            }
            if let q = arView.makeRaycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
               let h = arView.session.raycast(q).first {
                return h
            }
            return nil
        }

        /// Returns the candidate whose screen projection is nearest the crosshair, only if within snap radius.
        private static func linePinpointScreenAutolockWorld(
            candidates: [SIMD3<Float>],
            arView: ARView,
            screenCenter: CGPoint
        ) -> SIMD3<Float>? {
            guard !candidates.isEmpty else { return nil }
            let r = LineExtensionReticleConfig.screenSnapRadiusPoints
            var bestWorld: SIMD3<Float>?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for p in candidates {
                guard let sp = arView.project(p) else { continue }
                let d = hypot(sp.x - screenCenter.x, sp.y - screenCenter.y)
                guard d <= r else { continue }
                if d < bestDist {
                    bestDist = d
                    bestWorld = p
                }
            }
            return bestWorld
        }

        /// Closest committed segment (screen space) to the crosshair; index matches `committedSegments`.
        private static func closestCommittedSegmentScreenIndex(
            segments: [MeasurementSegment],
            arView: ARView,
            screenCenter: CGPoint
        ) -> (index: Int, screenDist: CGFloat)? {
            var bestIdx: Int?
            var bestD: CGFloat = .greatestFiniteMagnitude
            for (i, s) in segments.enumerated() {
                guard s.lengthMeters > 1e-5 else { continue }
                guard let sa = arView.project(s.start), let sb = arView.project(s.end) else { continue }
                let d = distanceFromPointToSegment2D(screenCenter, sa, sb)
                if bestIdx == nil || d < bestD {
                    bestD = d
                    bestIdx = i
                }
            }
            guard let idx = bestIdx else { return nil }
            return (idx, bestD)
        }

        /// Pill + extruded text stack for one segment readout (centroid-aligned like the original single label).
        private static func makeMeasurementLabelStack(displayText: String) -> Entity {
            let root = Entity()
            let pillMesh = MeshResource.generatePlane(
                width: MeasurementLabelStyle.pillWidth,
                depth: MeasurementLabelStyle.pillHeight
            )
            let pill = ModelEntity(mesh: pillMesh, materials: [MeasurementLabelStyle.borderedPillMaterial()])
            pill.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            pill.position = SIMD3<Float>(0, 0, -0.0006)
            let font = MeasurementLabelStyle.meshFontForGenerateText()
            let frame = MeasurementLabelStyle.textFrame
            let mesh = MeshResource.generateText(
                MeasurementLabelStyle.meshDisplayText(displayText),
                extrusionDepth: 0.0005,
                font: font,
                containerFrame: frame,
                alignment: .center,
                lineBreakMode: .byClipping
            )
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor.black)
            let textEnt = ModelEntity(mesh: mesh, materials: [mat])
            textEnt.position = SIMD3<Float>(repeating: 0)
            root.addChild(pill)
            root.addChild(textEnt)
            let box = textEnt.visualBounds(relativeTo: root)
            let span = box.max - box.min
            if simd_length(span) > 1e-6 {
                let c = (box.min + box.max) * 0.5
                textEnt.position = SIMD3<Float>(-c.x, -c.y, -c.z + 0.001)
            } else {
                textEnt.position = SIMD3<Float>(0, 0, 0.001)
            }
            return root
        }

        private static func distanceFromPointToSegment2D(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let abx = b.x - a.x
            let aby = b.y - a.y
            let apx = p.x - a.x
            let apy = p.y - a.y
            let ab2 = abx * abx + aby * aby
            if ab2 < 1e-8 {
                return hypot(apx, apy)
            }
            var t = (apx * abx + apy * aby) / ab2
            t = min(max(t, 0), 1)
            let cx = a.x + t * abx
            let cy = a.y + t * aby
            return hypot(p.x - cx, p.y - cy)
        }

        /// Merge nearly-coincident world points so shared pins render as one marker.
        static func dedupeWorldPositions(_ points: [SIMD3<Float>], tolerance: Float) -> [SIMD3<Float>] {
            var result: [SIMD3<Float>] = []
            result.reserveCapacity(points.count)
            for p in points {
                if !result.contains(where: { simd_distance($0, p) < tolerance }) {
                    result.append(p)
                }
            }
            return result
        }

        /// Same style as placing a mark (`ARMeasurementView` uses `.medium`).
        private func triggerMarkStyleHaptic() {
            guard hapticFeedbackEnabled else { return }
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        private func updatePinAutolockHaptics(pinWorld: SIMD3<Float>?) {
            if let p = pinWorld {
                if let prev = lastAutolockedPinWorld, simd_distance(p, prev) < 0.00015 {
                    return
                }
                lastAutolockedPinWorld = p
                triggerMarkStyleHaptic()
            } else {
                lastAutolockedPinWorld = nil
            }
        }

        /// Billboards every committed segment label; hides only the segment the crosshair is on (same mid-dot behavior as before). Flatten: no line mid interaction.
        private func updateCommittedSegmentLabelsHoverAndMidDot(
            arView: ARView,
            screenCenter: CGPoint,
            camForLabel: SIMD3<Float>,
            camUp: SIMD3<Float>
        ) {
            guard !committedSegments.isEmpty,
                  let container = committedSegmentLabelsContainer
            else {
                lineMidHoverDotEntity?.isEnabled = false
                return
            }

            let children = Array(container.children)
            guard children.count == committedSegments.count else { return }

            let threshold = LineExtensionReticleConfig.lineHoverScreenDistancePoints
            let hoverPick = Self.closestCommittedSegmentScreenIndex(
                segments: committedSegments,
                arView: arView,
                screenCenter: screenCenter
            )
            let hoverIndex = currentMode.applyLineHoverAndMidDot(hoverPick: hoverPick, threshold: threshold)

            for i in 0..<committedSegments.count {
                let seg = committedSegments[i]
                let root = children[i]
                guard seg.lengthMeters > 1e-5 else {
                    root.isEnabled = false
                    continue
                }
                let hideForHover = (hoverIndex != nil) && i == hoverIndex
                root.isEnabled = !hideForHover
                if hideForHover { continue }

                let labelPos = Self.measurementLabelWorldPosition(
                    segmentFrom: seg.start,
                    segmentTo: seg.end,
                    cameraWorld: camForLabel
                )
                root.position = labelPos
                let s = Self.measurementLabelUniformScaleForFixedScreenSize(
                    cameraWorld: camForLabel,
                    labelWorldPosition: labelPos
                )
                root.scale = SIMD3<Float>(repeating: s)
                root.orientation = Self.measurementLabelViewAlignedQuaternion(
                    labelPosition: labelPos,
                    segmentFrom: seg.start,
                    segmentTo: seg.end,
                    cameraWorld: camForLabel,
                    cameraUpWorld: camUp
                )
            }
        }

        // MARK: - Per-frame update loop

        private func publishFlattenScanCornersReady(_ arView: ARView) {
            let ready: Bool
            if isFlattenMode,
               flattenAdjustingPointIndex == nil,
               committedSegments.count == 3,
               draftSegmentStart == nil {
                ready = flattenMode.scanCornersVisible(in: arView)
            } else {
                ready = false
            }
            guard ready != lastFlattenScanCornersReady else { return }
            lastFlattenScanCornersReady = ready
            DispatchQueue.main.async {
                self.flattenScanCornersReady = ready
            }
        }

        func startUpdateLoop() {
            guard let arView else { return }

            updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) {
                [weak self] _ in
                guard let self = self, let arView = self.arView else { return }
                self.publishFlattenScanCornersReady(arView)
                let now = CACurrentMediaTime()

                guard let currentFrame = arView.session.currentFrame else {
                    self.consecutiveBadTrackingFrames += 1
                    if self.consecutiveBadTrackingFrames >= self.badTrackingThreshold {
                        self.hideRing()
                    }
                    return
                }

                // Update lighting guidance
                self.updateSmoothedAmbientIntensity(currentFrame.lightEstimate)
                self.updateTooDarkLightingDebounced()

                // Custom motion detection (replaces ARKit's excessive motion)
                let currentTransform = currentFrame.camera.transform
                let currentPos = SIMD3<Float>(
                    currentTransform.columns.3.x,
                    currentTransform.columns.3.y,
                    currentTransform.columns.3.z
                )

                if let lastTransform = self.lastCameraTransform {
                    let lastPos = SIMD3<Float>(
                        lastTransform.columns.3.x,
                        lastTransform.columns.3.y,
                        lastTransform.columns.3.z
                    )
                    let displacement = simd_distance(currentPos, lastPos)
                    let rotationDelta = Self.rotationDeltaRadians(from: lastTransform, to: currentTransform)
                    let motionScore = self.customExcessiveMotionDisplacementWeight * displacement
                        + self.customExcessiveMotionRotationWeight * rotationDelta

                    if motionScore > self.customExcessiveMotionThreshold {
                        self.customExcessiveMotionFrameCount += 1
                        if self.customExcessiveMotionFrameCount >= self.customExcessiveMotionShowThreshold {
                            if !self.customExcessiveMotionActive {
                                self.customExcessiveMotionActive = true
                                self.publishCustomExcessiveMotion(true)
                            }
                        }
                    } else {
                        // Decay counter
                        if self.customExcessiveMotionFrameCount > 0 {
                            self.customExcessiveMotionFrameCount -= 1
                        }
                        if self.customExcessiveMotionFrameCount == 0 && self.customExcessiveMotionActive {
                            self.customExcessiveMotionActive = false
                            self.publishCustomExcessiveMotion(false)
                        }
                    }
                }
                self.lastCameraTransform = currentTransform

                switch currentFrame.camera.trackingState {
                    case .normal:
                        updateARKitTrackingGuide(nil)
                        consecutiveBadTrackingFrames = 0
                    
                    case .limited(let reason):
                        consecutiveBadTrackingFrames += 1
                        updateARKitTrackingGuide(reason == .insufficientFeatures ? reason : nil)
                        updatePlacementGuide(.none)
                        if consecutiveBadTrackingFrames >= badTrackingThreshold {
                            hideRing()
                        }
                        return
                    
                    case .notAvailable:
                        consecutiveBadTrackingFrames += 1
                        updateARKitTrackingGuide(nil)
                        updatePlacementGuide(.none)
                        if consecutiveBadTrackingFrames >= badTrackingThreshold {
                            hideRing()
                        }
                        return
                }
                // if currentFrame.camera.trackingState != .normal {
                //     self.consecutiveBadTrackingFrames += 1
                //     if self.consecutiveBadTrackingFrames >= self.badTrackingThreshold {
                //         self.hideRing()
                //     }
                //     return
                // }
                // self.consecutiveBadTrackingFrames = 0

                // Hide the ring if coaching is active
                if self.isCoachingActive {
                    self.updatePlacementGuide(.none)
                    self.hideRing()
                    return
                }

                if self.isFlattenScanSnapshotCaptureActive || self.isFlattenScanActive {
                    self.ringEntity?.isEnabled = false
                    self.updatePlacementGuide(.none)
                    self.updatePinAutolockHaptics(pinWorld: nil)
                    self.latestPinAutolockWorld = nil
                    self.lineMidHoverDotEntity?.isEnabled = false
                    DispatchQueue.main.async { self.hasValidTarget = false }
                    return
                }

                if self.displayedTrackingGuideIssue != .none {
                    self.updatePlacementGuide(.none)
                    self.updatePinAutolockHaptics(pinWorld: nil)
                    self.latestPinAutolockWorld = nil
                    self.lineMidHoverDotEntity?.isEnabled = false
                    self.hideRing()
                    return
                }

                let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                let ct = currentFrame.camera.transform
                let camForLabel = SIMD3<Float>(ct.columns.3.x, ct.columns.3.y, ct.columns.3.z)
                let camUp = simd_normalize(SIMD3<Float>(ct.columns.1.x, ct.columns.1.y, ct.columns.1.z))

                if self.isIdentifyMode {
                    self.ringEntity?.isEnabled = false
                    self.updatePlacementGuide(.none)
                    self.updatePinAutolockHaptics(pinWorld: nil)
                    self.latestPinAutolockWorld = nil
                    self.lineMidHoverDotEntity?.isEnabled = false
                    self.currentMode.updateAfterReticle(
                        reticleWorld: .zero,
                        camWorld: camForLabel,
                        camUp: camUp
                    )
                    DispatchQueue.main.async { self.hasValidTarget = false }
                    return
                }

                self.currentMode.resetAutolockBookkeepingIfNeeded()
                if !self.committedSegments.isEmpty {
                    self.updateCommittedSegmentLabelsHoverAndMidDot(
                        arView: arView,
                        screenCenter: center,
                        camForLabel: camForLabel,
                        camUp: camUp
                    )
                } else {
                    self.lineMidHoverDotEntity?.isEnabled = false
                }

                // Planes: existing geometry → estimated
                let hit = self.raycastReticle(from: center, in: arView)

                func registerMiss() {
                    self.consecutiveHits = 0
                    self.consecutiveMisses += 1
                    if self.consecutiveMisses >= self.missThreshold {
                        self.hideRing()
                    }
                }

                let camPos = SIMD3<Float>(
                    currentFrame.camera.transform.columns.3.x,
                    currentFrame.camera.transform.columns.3.y,
                    currentFrame.camera.transform.columns.3.z
                )

                let pinCandidates = self.currentMode.pinCandidates()
                let pinLockWorld = Self.linePinpointScreenAutolockWorld(
                    candidates: pinCandidates,
                    arView: arView,
                    screenCenter: center
                )

                enum AimClassification {
                    case tooClose
                    case noSurface
                    case valid(targetPos: SIMD3<Float>, useCameraFacingNormal: Bool)
                }

                let aimClassification: AimClassification
                if let pin = pinLockWorld {
                    let distance = simd_distance(pin, camPos)
                    if distance < self.minReticlePlacementDistanceMeters {
                        aimClassification = .tooClose
                    } else if distance > 3.0 {
                        aimClassification = .noSurface
                    } else {
                        // When snapping to an endpoint/mid off the current raycast plane, orient the ring toward the camera.
                        aimClassification = .valid(targetPos: pin, useCameraFacingNormal: true)
                    }
                } else if let h = hit {
                    let hitTransform = h.worldTransform
                    let hitPos = SIMD3<Float>(hitTransform.columns.3.x, hitTransform.columns.3.y, hitTransform.columns.3.z)
                    let distance = simd_distance(hitPos, camPos)
                    if distance < self.minReticlePlacementDistanceMeters {
                        aimClassification = .tooClose
                    } else if distance > 3.0 {
                        aimClassification = .noSurface
                    } else {
                        aimClassification = .valid(targetPos: hitPos, useCameraFacingNormal: false)
                    }
                } else {
                    aimClassification = .noSurface
                }

                let targetPos: SIMD3<Float>
                let useCameraFacingNormal: Bool
                switch aimClassification {
                case .tooClose:
                    self.updatePlacementGuide(.tooClose)
                    self.updatePinAutolockHaptics(pinWorld: nil)
                    self.latestPinAutolockWorld = nil
                    // Too-close is promoted guidance: hide immediately so crosshair/+ reflect invalid aim
                    // without waiting for missThreshold debounce.
                    self.hideRing()
                    return
                case .noSurface:
                    self.updatePlacementGuide(.findNearbySurface)
                    self.updatePinAutolockHaptics(pinWorld: nil)
                    self.latestPinAutolockWorld = nil
                    registerMiss()
                    return
                case .valid(let classifiedPos, let classifiedUseCameraFacingNormal):
                    self.updatePlacementGuide(.none)
                    targetPos = classifiedPos
                    useCameraFacingNormal = classifiedUseCameraFacingNormal
                }

                self.updatePinAutolockHaptics(pinWorld: pinLockWorld)
                self.latestPinAutolockWorld = pinLockWorld

                // Valid aim (surface raycast and/or line pinpoint autolock)
                self.consecutiveMisses = 0
                let ringWasVisible = self.ringEntity?.isEnabled == true
                if !ringWasVisible {
                    self.consecutiveHits += 1
                    guard self.consecutiveHits >= self.showThreshold else { return }
                }

                // Stable rotation: low-pass the normal before building basis (reduces visible spin on 3-arc ring).
                let rawNormal: SIMD3<Float>
                if useCameraFacingNormal {
                    rawNormal = simd_normalize(camPos - targetPos)
                } else if let h = hit {
                    let hitTransform = h.worldTransform
                    rawNormal = simd_normalize(SIMD3<Float>(hitTransform.columns.1.x, hitTransform.columns.1.y, hitTransform.columns.1.z))
                } else {
                    rawNormal = simd_normalize(camPos - targetPos)
                }
                let normal: SIMD3<Float>
                if let prevN = self.smoothNormal {
                    normal = simd_normalize(simd_mix(prevN, rawNormal, SIMD3<Float>(repeating: self.normalSmoothAlpha)))
                } else {
                    normal = rawNormal
                }
                self.smoothNormal = normal

                let camFwd = -SIMD3<Float>(
                    currentFrame.camera.transform.columns.2.x,
                    currentFrame.camera.transform.columns.2.y,
                    currentFrame.camera.transform.columns.2.z
                )
                let projected = camFwd - simd_dot(camFwd, normal) * normal
                let ref: SIMD3<Float>
                if simd_length(projected) > 0.001 {
                    ref = simd_normalize(projected)
                } else {
                    ref = abs(simd_dot(normal, SIMD3<Float>(0, 1, 0))) < 0.99
                        ? SIMD3<Float>(0, 1, 0)
                        : SIMD3<Float>(0, 0, 1)
                }
                let tangentX = simd_normalize(simd_cross(ref, normal))
                let tangentZ = simd_cross(tangentX, normal)
                let targetRot = simd_quatf(simd_float3x3(columns: (tangentX, normal, tangentZ)))

                // Velocity-adaptive delta-time smoothing
                let pos: SIMD3<Float>
                let rot: simd_quatf

                if let prevPos = self.smoothPosition, let prevRot = self.smoothRotation, self.lastUpdateTime > 0 {
                    let dt = Float(now - self.lastUpdateTime)
                    let clampedDt = min(max(dt, 0.001), 0.1)

                    let displacement = simd_distance(targetPos, prevPos)
                    let speed = displacement / clampedDt
                    let velocityFactor = min(speed / 0.5, 1.0)

                    let adaptivePosAlpha: Float = 0.08 + velocityFactor * 0.42
                    // Slower rotation blend at rest = less jitter; still responsive when moving fast.
                    let adaptiveRotAlpha: Float = 0.035 + velocityFactor * 0.22

                    let posT = 1.0 - pow(1.0 - adaptivePosAlpha, clampedDt * 60.0)
                    let rotT = 1.0 - pow(1.0 - adaptiveRotAlpha, clampedDt * 60.0)

                    pos = simd_mix(prevPos, targetPos, SIMD3<Float>(repeating: posT))
                    rot = simd_slerp(prevRot, targetRot, rotT)
                } else {
                    pos = targetPos
                    rot = targetRot
                }
                self.lastUpdateTime = now

                self.smoothPosition = pos
                self.smoothRotation = rot

                self.ringEntity?.position = pos
                self.ringEntity?.orientation = rot
                self.ringEntity?.isEnabled = true
                self.latestReticleWorldPosition = pos

                self.currentMode.updateAfterReticle(
                    reticleWorld: pos,
                    camWorld: camForLabel,
                    camUp: camUp
                )

                DispatchQueue.main.async { self.hasValidTarget = true }
            }
        }

        /// Debounce placement issues locally, then re-resolve global tracking guide priority.
        private func updatePlacementGuide(_ issue: PlacementGuideIssue) {
            if issue == placementGuideDebounceIssue {
                placementGuideDebounceFrameCount += 1
            } else {
                placementGuideDebounceIssue = issue
                placementGuideDebounceFrameCount = 1
            }

            let threshold = max(1, appliedTrackingGuideShowThreshold)
            guard placementGuideDebounceFrameCount >= threshold else { return }
            guard placementGuidePromotedIssue != issue else { return }
            placementGuidePromotedIssue = issue
            publishMergedTrackingGuideIfNeeded()
        }

        // MARK: - Simplified ARKit tracking (no more excessive motion)
        private func updateARKitTrackingGuide(_ reason: ARCamera.TrackingState.Reason?) {
            let issue: ARKitGuideIssue
            switch reason {
            case .insufficientFeatures:
                issue = .findNearbySurface
            default:
                issue = .none
            }

            let threshold: Int
            let frameCount: Int
            switch issue {
            case .findNearbySurface:
                arKitInsufficientFeaturesFrameCount += 1
                arKitNoneFrameCount = 0
                threshold = arKitInsufficientFeaturesShowThreshold
                frameCount = arKitInsufficientFeaturesFrameCount
            case .none:
                arKitNoneFrameCount += 1
                arKitInsufficientFeaturesFrameCount = 0
                threshold = arKitClearShowThreshold
                frameCount = arKitNoneFrameCount
            case .excessiveMotion:
                // No longer handled here - using custom detection
                return
            }

            guard frameCount >= threshold else { return }
            guard arKitGuidePromotedIssue != issue else { return }
            
            arKitGuidePromotedIssue = issue
            publishMergedTrackingGuideIfNeeded()
        }

        /// True while flatten scan preview/processing hides placement + tracking banner chrome.
        private var placementBannerChromeMutedForFlattenCapture: Bool {
            isFlattenScanActive || flattenScanOccludesPlacementChrome
        }

        /// Clears SwiftUI capsules and blocks banner republish until flatten pipeline releases
        /// `flattenScanOccludesPlacementChrome`.
        func suppressPlacementBannerChromeDuringFlattenPipelineHandoff() {
            flattenScanOccludesPlacementChrome = true
            cancelTrackingGuideTransition()
            let flush = { [weak self] in
                guard let self else { return }
                self.placementWarningMessage = ""
                self.trackingGuideMessage = ""
                self.activeTrackingReason = nil
                self.displayedTrackingGuideIssue = .none
                self.trackingGuideDisplayedAt = nil
            }
            if Thread.isMainThread {
                flush()
            } else {
                DispatchQueue.main.sync(execute: flush)
            }
        }

        // MARK - Lighting guidance
        private func updateSmoothedAmbientIntensity(_ lightEstimate: ARLightEstimate?) {
            guard let lightEstimate else { return }
            let newValue = lightEstimate.ambientIntensity
            if let previous = smoothedAmbientIntensity {
                smoothedAmbientIntensity = 
                    ambientIntensityEMAAlpha * newValue + (1 - ambientIntensityEMAAlpha) * previous
            } else {
                smoothedAmbientIntensity = newValue
            }
        }

        private func updateTooDarkLightingDebounced() {
            guard let smoothed = smoothedAmbientIntensity else { 
                // No estimate this frame, clear everything
                tooDarkConsecutiveFrames = 0
                isTooDark = false
                return
            }

            // If enough consecutive frames are too dark, set the flag
            if smoothed < tooDarkThreshold {
                tooDarkConsecutiveFrames += 1
                guard tooDarkConsecutiveFrames >= tooDarkConsecutiveFramesThreshold else { return }
                isTooDark = true
            } 
            else {
                tooDarkConsecutiveFrames = 0
                isTooDark = false
            }
            publishLightingGuide()
        }

        // Update the lighting guidance publisher
        private func publishLightingGuide() {
            let newIssue: ResolvedTrackingGuideIssue = isTooDark ? .tooDark : .none
            guard lightingGuidePromotedIssue != newIssue else { return }

            lightingGuidePromotedIssue = newIssue
            publishMergedTrackingGuideIfNeeded()
        }


        /// Angle (radians) between previous and current camera orientations (minimal rotation delta).
        private static func rotationDeltaRadians(from previous: simd_float4x4, to current: simd_float4x4) -> Float {
            let pr = simd_float3x3(
                SIMD3(previous.columns.0.x, previous.columns.0.y, previous.columns.0.z),
                SIMD3(previous.columns.1.x, previous.columns.1.y, previous.columns.1.z),
                SIMD3(previous.columns.2.x, previous.columns.2.y, previous.columns.2.z)
            )
            let cr = simd_float3x3(
                SIMD3(current.columns.0.x, current.columns.0.y, current.columns.0.z),
                SIMD3(current.columns.1.x, current.columns.1.y, current.columns.1.z),
                SIMD3(current.columns.2.x, current.columns.2.y, current.columns.2.z)
            )
            let delta = simd_mul(cr, simd_transpose(pr))
            let trace =
                delta.columns.0.x + delta.columns.1.y + delta.columns.2.z
            let cosTheta = Float(
                max(-1, min(1, Double((trace - 1) * 0.5)))
            )
            return acos(cosTheta)
        }

        // Update the custom motion publisher
        private func publishCustomExcessiveMotion(_ isActive: Bool) {
            let newIssue: ResolvedTrackingGuideIssue = isActive ? .excessiveMotion : .none
            guard customMotionPromotedIssue != newIssue else { return }
            
            customMotionPromotedIssue = newIssue
            if isActive {
                arPlacementLog.notice("Custom excessive motion: ACTIVE")
            } else {
                arPlacementLog.notice("Custom excessive motion: CLEARED")
            }
            publishMergedTrackingGuideIfNeeded()
        }


        // Update the merge resolution to check BOTH sources
        private func resolveMergedTrackingGuideIssue() -> ResolvedTrackingGuideIssue {
            // Priority: tooDark >tooClose > excessiveMotion > findNearbySurface > none
            
            if lightingGuidePromotedIssue == .tooDark {
                return .tooDark
            }

            if placementGuidePromotedIssue == .tooClose {
                return .tooClose
            }
            
            // ✅ Check custom motion state separately
            if customMotionPromotedIssue == .excessiveMotion {
                return .excessiveMotion
            }
            
            // Now check ARKit's promoted issue (which no longer includes excessive motion)
            if placementGuidePromotedIssue == .findNearbySurface || arKitGuidePromotedIssue == .findNearbySurface {
                return .findNearbySurface
            }
            
            return .none
        }

        /// Single publish point for SwiftUI tracking guide bindings with global priority:
        /// tooDark > tooClose > excessiveMotion > findNearbySurface.
        /// Resolved issue persists while unchanged. Switching to another **non-empty** guide commits
        /// immediately (no minimum-delay wait). Clearing the banner waits out the remainder of
        /// `trackingGuideMinimumDisplayDuration` so short flickers don't hide guidance too soon.
        private func publishMergedTrackingGuideIfNeeded() {
            if placementBannerChromeMutedForFlattenCapture {
                cancelTrackingGuideTransition()
                return
            }
            let resolvedIssue = resolveMergedTrackingGuideIssue()
            if resolvedIssue == displayedTrackingGuideIssue {
                cancelTrackingGuideTransition()
                return
            }
            scheduleTrackingGuideTransition()
        }

        private func cancelTrackingGuideTransition() {
            trackingGuideTransitionWorkItem?.cancel()
            trackingGuideTransitionWorkItem = nil
        }

        private func scheduleTrackingGuideTransition() {
            cancelTrackingGuideTransition()

            let resolved = resolveMergedTrackingGuideIssue()

            if displayedTrackingGuideIssue == .none {
                commitTrackingGuideDisplay(resolved)
                return
            }

            // Any change to another concrete guide swaps immediately — no minimum wait between messages.
            if resolved != .none {
                commitTrackingGuideDisplay(resolved)
                return
            }

            // Dismissing: honor minimum elapsed time since this guide appeared.
            let elapsed = trackingGuideDisplayedAt.map { Date().timeIntervalSince($0) }
                ?? Self.trackingGuideMinimumDisplayDuration
            let delay = max(0, Self.trackingGuideMinimumDisplayDuration - elapsed)

            if delay <= 0 {
                commitTrackingGuideDisplay(resolved)
                return
            }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.trackingGuideTransitionWorkItem = nil
                let latestIssue = self.resolveMergedTrackingGuideIssue()
                guard latestIssue == .none else { return }
                self.commitTrackingGuideDisplay(latestIssue)
            }
            trackingGuideTransitionWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func commitTrackingGuideDisplay(_ issue: ResolvedTrackingGuideIssue) {
            displayedTrackingGuideIssue = issue
            trackingGuideDisplayedAt = issue == .none ? nil : Date()

            let guidance = messageAndReason(for: issue)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeTrackingReason = guidance.reason
                self.trackingGuideMessage = guidance.message
                self.trackingGuideKind = .instruction
            }
        }

        private func messageAndReason(for resolvedIssue: ResolvedTrackingGuideIssue) -> (message: String, reason: ARCamera.TrackingState.Reason?) {
            switch resolvedIssue {
            case .tooDark:
                return ("More light is required", nil)
            case .tooClose:
                return ("Move farther away", nil)
            case .excessiveMotion:
                return ("Slow down", .excessiveMotion)
            case .findNearbySurface:
                // Keep reason specific only when ARKit is the sole winner.
                let reason = (arKitGuidePromotedIssue == .findNearbySurface && placementGuidePromotedIssue != .findNearbySurface)
                    ? ARCamera.TrackingState.Reason.insufficientFeatures
                    : nil
                return ("Find a nearby surface to measure", reason)
            case .none:
                return ("", nil)
            }
        }

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
            // arPlacementLog.debug(
            //     "syncPlaceAndClear: placeToken=\(placeToken) lastProcessedPlace=\(self.lastProcessedPlaceToken) clearToken=\(clearToken) lastProcessedClear=\(self.lastProcessedClearToken)"
            // )
            if placeToken != lastProcessedPlaceToken {
                // arPlacementLog.notice("syncPlaceAndClear: processing NEW placeMarkToken=\(placeToken)")
                lastProcessedPlaceToken = placeToken
                placeMarkAtReticle()
            } else {
                // arPlacementLog.debug("syncPlaceAndClear: skip place (token unchanged)")
            }
            if clearToken != lastProcessedClearToken {
                // arPlacementLog.notice("syncPlaceAndClear: processing clearMarksToken=\(clearToken)")
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

        /// Renders the AR view to an image; parent shows preview and runs Save / Share only after explicit confirmation.
        private func captureScreenshotForPreview() {
            guard !placementBannerChromeMutedForFlattenCapture else { return }
            guard let arView = arView else { return }
            arView.snapshot(saveToHDR: false) { [weak self] image in
                guard let self, let image else { return }
                DispatchQueue.main.async {
                    self.screenshotPreviewImage = image
                }
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

        private func placeMarkAtReticle() {
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
                // arPlacementLog.warning("placeMarkAtReticle: ABORT latestReticleWorldPosition is nil (reticle may not have written a frame yet)")
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

        private func clearAllMeasurements() {
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

        private func rebuildCommittedSegmentLabelEntities() {
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

        private func clearSingleMarkPreviewVisuals() {
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
                // arPlacementLog.warning(
                //     "refreshMeasurementVisuals: ABORT missing entities committed=\(self.committedLinesContainer != nil) preview=\(self.previewLinesContainer != nil) markers=\(self.vertexMarkersContainer != nil) segLabels=\(self.committedSegmentLabelsContainer != nil) draftLabel=\(self.draftPreviewLabelRoot != nil) segments=\(self.committedSegments.count) draft=\(self.draftSegmentStart != nil)"
                // )
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

        private func rebuildDraftPreviewLabelMesh(text: String) {
            guard let textEntity = draftLabelTextEntity, let parent = textEntity.parent else { return }
            let font = MeasurementLabelStyle.meshFontForGenerateText()
            let frame = MeasurementLabelStyle.textFrame
            let mesh = MeshResource.generateText(
                MeasurementLabelStyle.meshDisplayText(text),
                extrusionDepth: 0.0005,
                font: font,
                containerFrame: frame,
                alignment: .center,
                lineBreakMode: .byClipping
            )
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor.black)
            textEntity.position = SIMD3<Float>(repeating: 0)
            textEntity.model = ModelComponent(mesh: mesh, materials: [mat])
            let box = textEntity.visualBounds(relativeTo: parent)
            let span = box.max - box.min
            if simd_length(span) > 1e-6 {
                let center = (box.min + box.max) * 0.5
                textEntity.position = SIMD3<Float>(-center.x, -center.y, -center.z + 0.001)
            } else {
                textEntity.position = SIMD3<Float>(0, 0, 0.001)
            }
        }

        /// Scale ∝ distance so angular size on screen stays ~constant (RealityKit has no z‑index; this is the usual AR HUD trick).
        private static func measurementLabelUniformScaleForFixedScreenSize(
            cameraWorld: SIMD3<Float>,
            labelWorldPosition: SIMD3<Float>
        ) -> Float {
            let d = simd_distance(cameraWorld, labelWorldPosition)
            guard d > 1e-4 else {
                return MeasurementLabelStyle.labelDistanceScaleMax
            }
            let ref = MeasurementLabelStyle.labelReferenceCameraDistanceMeters
            var s = d / ref
            s = min(max(s, MeasurementLabelStyle.labelDistanceScaleMin), MeasurementLabelStyle.labelDistanceScaleMax)
            return s
        }

        /// View‑aligned billboard: +Z toward camera; +X follows **camera right** (projected into the label plane) so the string
        /// stays left‑to‑right on screen. Segment direction is only a fallback when the line is parallel to the view.
        private static func measurementLabelViewAlignedQuaternion(
            labelPosition: SIMD3<Float>,
            segmentFrom a: SIMD3<Float>,
            segmentTo b: SIMD3<Float>,
            cameraWorld: SIMD3<Float>?,
            cameraUpWorld: SIMD3<Float>?
        ) -> simd_quatf {
            let delta = b - a
            let dLen = simd_length(delta)
            let worldUp = SIMD3<Float>(0, 1, 0)
            guard dLen > 1e-5 else {
                if let cam = cameraWorld {
                    return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
                }
                return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }
            let dir = delta / dLen

            guard let cam = cameraWorld else {
                return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }
            let toCam = cam - labelPosition
            let vLen = simd_length(toCam)
            guard vLen > 1e-5 else {
                return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
            }
            let zAxis = toCam / vLen

            let forwardView = simd_normalize(labelPosition - cam)
            let upGuess = cameraUpWorld.map { simd_normalize($0) } ?? worldUp
            var upCam = upGuess - forwardView * simd_dot(upGuess, forwardView)
            var upCL = simd_length(upCam)
            if upCL < 1e-4 {
                upCam = worldUp - forwardView * simd_dot(worldUp, forwardView)
                upCL = simd_length(upCam)
            }
            guard upCL > 1e-5 else {
                return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
            }
            upCam /= upCL

            var rightView = simd_cross(forwardView, upCam)
            var rvLen = simd_length(rightView)
            if rvLen < 1e-4 {
                rightView = simd_cross(forwardView, SIMD3<Float>(1, 0, 0))
                rvLen = simd_length(rightView)
            }
            guard rvLen > 1e-5 else {
                return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
            }
            rightView /= rvLen

            var xAxis = rightView - zAxis * simd_dot(rightView, zAxis)
            var xLen = simd_length(xAxis)
            if xLen < 1e-4 {
                var t = dir - zAxis * simd_dot(dir, zAxis)
                var tLen = simd_length(t)
                if tLen < 1e-4 {
                    t = simd_cross(zAxis, worldUp)
                    tLen = simd_length(t)
                    if tLen < 1e-4 {
                        t = simd_cross(zAxis, SIMD3<Float>(1, 0, 0))
                        tLen = simd_length(t)
                    }
                }
                guard tLen > 1e-5 else {
                    return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
                }
                t /= tLen
                xAxis = t
            } else {
                xAxis /= xLen
            }
            if simd_dot(xAxis, rightView) < 0 {
                xAxis = -xAxis
            }

            let yAxis = simd_normalize(simd_cross(zAxis, xAxis))
            guard simd_length(yAxis) > 1e-5 else {
                return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
            }

            let rot = simd_float3x3(columns: (xAxis, yAxis, zAxis))
            var q = simd_quatf(rot)
            q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)))

            let toC = cam - labelPosition
            if simd_length(toC) > 1e-5 {
                func frontFacesCamera(_ quat: simd_quatf) -> Bool {
                    simd_dot(simd_act(quat, SIMD3<Float>(0, 0, 1)), toC) >= 0
                }
                if !frontFacesCamera(q) {
                    q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)))
                }
                if !frontFacesCamera(q) {
                    q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
                }
            }
            // 90° CCW on screen about the view axis (local +Z). Use −π/2 if you want the other direction.
            q = simd_mul(q, simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            return q
        }

        private static func quaternionFacingCameraOnly(labelPosition: SIMD3<Float>, cameraWorld: SIMD3<Float>) -> simd_quatf {
            let toCam = cameraWorld - labelPosition
            let vLen = simd_length(toCam)
            guard vLen > 1e-5 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
            let zAxis = toCam / vLen
            let worldUp = SIMD3<Float>(0, 1, 0)
            var xAxis = simd_normalize(simd_cross(worldUp, zAxis))
            if simd_length(xAxis) < 1e-5 {
                xAxis = SIMD3<Float>(1, 0, 0)
            }
            let yAxis = simd_normalize(simd_cross(zAxis, xAxis))
            let rot = simd_float3x3(columns: (xAxis, yAxis, zAxis))
            var q = simd_quatf(rot)
            q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)))

            let toC = cameraWorld - labelPosition
            if simd_length(toC) > 1e-5 {
                func frontFacesCamera(_ quat: simd_quatf) -> Bool {
                    simd_dot(simd_act(quat, SIMD3<Float>(0, 0, 1)), toC) >= 0
                }
                if !frontFacesCamera(q) {
                    q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)))
                }
                if !frontFacesCamera(q) {
                    q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
                }
            }
            q = simd_mul(q, simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            return q
        }

        /// World position: segment midpoint, nudged toward `cameraWorld` so the billboard draws in front of the line.
        private static func measurementLabelWorldPosition(
            segmentFrom a: SIMD3<Float>,
            segmentTo b: SIMD3<Float>,
            cameraWorld: SIMD3<Float>? = nil
        ) -> SIMD3<Float> {
            let mid = (a + b) * 0.5
            guard let cam = cameraWorld else { return mid }
            let toCam = cam - mid
            let len = simd_length(toCam)
            guard len > 1e-5 else { return mid }
            return mid + (toCam / len) * MeasurementLabelStyle.labelTowardCameraBiasMeters
        }

        /// Rotates +Y to align with `direction` (unit vector).
        private static func quatAligningPositiveY(to direction: SIMD3<Float>) -> simd_quatf {
            let y = SIMD3<Float>(0, 1, 0)
            let d = simd_normalize(direction)
            let c = simd_cross(y, d)
            let cl = simd_length(c)
            if cl < 1e-6 {
                return simd_dot(y, d) >= 0 ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) : simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            }
            let axis = c / cl
            let angle = atan2(cl, simd_dot(y, d))
            return simd_quatf(angle: angle, axis: axis)
        }

        // MARK: - Ring mesh generation

        /// Three arc segments with equal gaps (broken circle).
        static func generateRingMesh(innerRadius: Float, outerRadius: Float, arcCount: Int = 3, segmentsPerArc: Int = 16) throws -> MeshResource {
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var indices: [UInt32] = []

            let arcSpan: Float = (2.0 * .pi / Float(arcCount)) * 0.75
            let gapSpan: Float = (2.0 * .pi / Float(arcCount)) - arcSpan

            for arc in 0..<arcCount {
                let arcStart = Float(arc) * (arcSpan + gapSpan)
                let baseIndex = UInt32(positions.count)

                for i in 0...segmentsPerArc {
                    let t = Float(i) / Float(segmentsPerArc)
                    let angle = arcStart + t * arcSpan
                    let c = cosf(angle)
                    let s = sinf(angle)

                    positions.append(SIMD3<Float>(outerRadius * c, 0, outerRadius * s))
                    normals.append(SIMD3<Float>(0, 1, 0))

                    positions.append(SIMD3<Float>(innerRadius * c, 0, innerRadius * s))
                    normals.append(SIMD3<Float>(0, 1, 0))
                }

                for i in 0..<segmentsPerArc {
                    let o0 = baseIndex + UInt32(i * 2)
                    let i0 = baseIndex + UInt32(i * 2 + 1)
                    let o1 = baseIndex + UInt32((i + 1) * 2)
                    let i1 = baseIndex + UInt32((i + 1) * 2 + 1)

                    indices.append(contentsOf: [o0, i0, o1])
                    indices.append(contentsOf: [i0, i1, o1])
                }
            }

            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.primitives = .triangles(indices)

            return try MeshResource.generate(from: [descriptor])
        }

        func setupRingEntity(in arView: ARView) {
            guard let mesh = try? Self.generateRingMesh(innerRadius: 0.046, outerRadius: 0.050) else { return }

            var material = UnlitMaterial()
            material.color = .init(tint: .white.withAlphaComponent(0.9))

            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.isEnabled = false

            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)

            ringEntity = entity
            ringAnchor = anchor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isCoachingActive: $isCoachingActive,
            isRelocalizing: $isRelocalizing,
            hasValidTarget: $hasValidTarget,
            measurementReadout: $measurementReadout,
            markCount: $markCount,
            flattenSegmentCount: $flattenSegmentCount,
            measurementModeRaw: $measurementModeRaw,
            measurementUnitRaw: $measurementUnitRaw,
            screenshotPreviewImage: $screenshotPreviewImage,
            flattenScanPreviewImage: $flattenScanPreviewImage,
            flattenScanResultImage: $flattenScanResultImage,
            flattenShapeFindings: $flattenShapeFindings,
            flattenDetectionPreviewImage: $flattenDetectionPreviewImage,
            isFlattenScanActive: $isFlattenScanActive,
            flattenScanSigmas: $flattenScanSigmas,
            flattenScanCornersReady: $flattenScanCornersReady,
            hapticFeedbackEnabled: $hapticFeedbackEnabled,
            placementWarningMessage: $placementWarningMessage,
            placementWarningToken: $placementWarningToken,
            placementBannerKind: $placementBannerKind,
            flattenRelocationActive: $flattenRelocationActive,
            activeTrackingReason: $activeTrackingReason,
            trackingGuideMessage: $trackingGuideMessage,
            trackingGuideKind: $trackingGuideKind,
            identifyDetections: $identifyDetections
        )
    }

    /// Enables scene mesh reconstruction on LiDAR devices; unchanged on non-LiDAR.
    private static func makeWorldTrackingConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        return configuration
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let configuration = Self.makeWorldTrackingConfiguration()
        arView.session.run(configuration)

        DispatchQueue.main.async {
            context.coordinator.hasValidTarget = false
        }

        context.coordinator.arView = arView
        context.coordinator.appliedTrackingGuideShowThreshold = trackingGuideShowThreshold
        context.coordinator.setupRingEntity(in: arView)
        context.coordinator.setupMeasurementEntities(in: arView)
        context.coordinator.startUpdateLoop()

        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingOverlay.session = arView.session
        coachingOverlay.goal = .anyPlane
        coachingOverlay.delegate = context.coordinator

        coachingOverlay.frame = arView.bounds
        arView.addSubview(coachingOverlay)
        context.coordinator.coachingOverlay = coachingOverlay

        arView.session.delegate = context.coordinator

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Log representable’s current bindings (source of truth from SwiftUI) vs coordinator reads inside sync.
        // arPlacementLog.debug(
        //     "updateUIView: representable placeMarkToken=\(placeMarkToken) clearMarksToken=\(clearMarksToken)"
        // )
        context.coordinator.appliedMeasurementModeRaw = measurementModeRaw
        context.coordinator.appliedTrackingGuideShowThreshold = trackingGuideShowThreshold
        context.coordinator.syncMeasurementModeFromSwiftUI(measurementModeRaw)
        context.coordinator.syncPlaceAndClearTokensIfNeeded(placeToken: placeMarkToken, clearToken: clearMarksToken)
        context.coordinator.syncScreenshotTokenIfNeeded(token: screenshotToken)
        context.coordinator.syncFlattenScanTokenIfNeeded(token: flattenScanToken)
        context.coordinator.syncMeasurementUnitFromSwiftUI(measurementUnitRaw)
        context.coordinator.syncFlattenFooterHeightFromSwiftUI(flattenFooterHeight)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.teardownSession()
    }
}

#Preview {
    ARSceneView(
        isCoachingActive: .constant(true),
        isRelocalizing: .constant(false),
        hasValidTarget: .constant(false),
        measurementReadout: .constant("—"),
        markCount: .constant(0),
        flattenSegmentCount: .constant(0),
        measurementModeRaw: .constant(ARFooterFeature.ruler.rawValue),
        measurementUnitRaw: .constant(MeasurementUnit.metric.rawValue),
        placeMarkToken: .constant(0),
        clearMarksToken: .constant(0),
        screenshotToken: .constant(0),
        screenshotPreviewImage: .constant(nil),
        flattenScanToken: .constant(0),
        flattenScanPreviewImage: .constant(nil),
        flattenScanResultImage: .constant(nil),
        flattenShapeFindings: .constant([]),
        flattenDetectionPreviewImage: .constant(nil),
        isFlattenScanActive: .constant(false),
        flattenScanSigmas: .constant([]),
        flattenScanCornersReady: .constant(false),
        hapticFeedbackEnabled: .constant(true),
        placementWarningMessage: .constant(""),
        placementWarningToken: .constant(0),
        placementBannerKind: .constant(.alert),
        flattenRelocationActive: .constant(false),
        flattenFooterHeight: .constant(0),
        trackingGuideShowThreshold: 6,
        activeTrackingReason: .constant(nil),
        trackingGuideMessage: .constant(""),
        trackingGuideKind: .constant(.instruction),
        identifyDetections: .constant([])
    )
}
