//
//  ARSceneView.swift
//  Meigan
//
//  `UIViewRepresentable` wrapper around RealityKit's `ARView` plus the `Coordinator` that owns
//  all AR-side state. The coordinator's behavior is split into extensions:
//  - `+Session.swift`: pause / resume / teardown, ARKit + coaching delegates
//  - `+Reticle.swift`: raycast reticle, autolock, haptics, ring mesh
//  - `+UpdateLoop.swift`: per-frame RealityKit update loop
//  - `+TrackingGuide.swift`: placement / tracking / lighting guidance banners
//  - `+Sync.swift`: SwiftUI → coordinator token and setting sync, entity setup
//  - `+Snapshots.swift`: screenshot capture and flatten dual-snapshot decorations
//  - `+Measurements.swift`: placing, clearing, and rebuilding measurement geometry
//  - `+Labels.swift`: 3D readout label meshes, scaling, and orientation
//

import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

struct ARSceneView: UIViewRepresentable {
    /// When true, pauses camera capture and the update loop without destroying the AR view (e.g. settings sheet).
    var isSessionPaused: Bool
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
        var hasCompletedCoachingOnce = false
        var appliedSessionPaused = false
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

        var ringAnchor: AnchorEntity?
        var ringEntity: ModelEntity?

        /// Last smoothed reticle position for placing marks (world space).
        var latestReticleWorldPosition: SIMD3<Float>?

        // Measurement visuals (world anchor at origin)
        var measurementAnchor: AnchorEntity?
        /// Solid geometry for all committed edges (never cleared by preview updates).
        var committedLinesContainer: Entity?
        /// Dotted preview only while placing the free end of the current segment.
        var previewLinesContainer: Entity?
        /// White spheres at deduped joints (committed vertices + draft start).
        var vertexMarkersContainer: Entity?
        var markerSphereMesh: MeshResource?
        var lineDashSegmentMesh: MeshResource?
        /// One billboard stack (pill + text) per committed segment, oldest → newest.
        var committedSegmentLabelsContainer: Entity?
        /// Preview readout while aiming the free end of the draft segment.
        var draftPreviewLabelRoot: Entity?
        var draftLabelPillEntity: ModelEntity?
        var draftLabelTextEntity: ModelEntity?
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
        /// Mirrored from `ARSceneView.updateUIView` every frame for screenshot compositing.
        var appliedIdentifyDetections: [IdentifyDetection] = []
        /// Mirrored from the representable each SwiftUI update so the RealityKit update thread never reads `@Binding`s.
        var appliedTrackingGuideShowThreshold: Int = 6

        var isFlattenMode: Bool {
            appliedMeasurementModeRaw == ARFooterFeature.flatten.rawValue
        }

        var isIdentifyMode: Bool {
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

        var lastProcessedPlaceToken: Int = 0
        var lastProcessedClearToken: Int = 0
        var lastProcessedScreenshotToken: Int = 0
        var lastProcessedFlattenScanToken: Int = 0
        var lastSyncedMeasurementUnitRaw: String = ""
        var lastSyncedMeasurementModeRaw: String = ARFooterFeature.ruler.rawValue
        var lastSyncedFlattenFooterHeight: CGFloat = 0

        // Smoothing state (nil = snap to first hit)
        var smoothPosition: SIMD3<Float>?
        var smoothRotation: simd_quatf?
        /// Low-pass filtered surface normal — cuts twist/spin from noisy raycast normals (broken ring makes this visible).
        var smoothNormal: SIMD3<Float>?
        var lastUpdateTime: CFTimeInterval = 0
        /// Previous frame's raw raycast target; drives the velocity-adaptive smoothing from
        /// actual target motion (not target-vs-smoothed distance, which under-reports slow pans).
        var lastRawTargetPos: SIMD3<Float>?
        /// Lightly filtered target speed (m/s) so single-frame raycast jitter doesn't spike the alpha.
        var smoothedTargetSpeed: Float = 0
        /// Camera→target distance from the last real hit. During the miss-hold debounce window the
        /// ring is re-projected along the current center ray at this depth so it stays under the dot.
        var lastReticleDepthMeters: Float?

        /// Debounce validity: hide after N consecutive bad frames; show after N consecutive good frames (when hidden).
        var consecutiveMisses = 0
        var consecutiveHits = 0
        /// Higher = fewer spurious hides when ARKit drops a few frames on a valid surface (e.g. stationary aim).
        let missThreshold = 12
        let showThreshold = 2
        let normalSmoothAlpha: Float = 0.14
        let minReticlePlacementDistanceMeters: Float = 0.15
        /// Frame-to-frame raycast jump beyond this means the aim crossed onto a different
        /// surface (or off an edge): snap the ring instead of blending through mid-air.
        let reticleSurfaceSnapDistanceMeters: Float = 0.1

        /// Avoid hiding reticle on single-frame tracking flicker.
        var consecutiveBadTrackingFrames = 0
        let badTrackingThreshold = 6

        // Lighting guidance
        var smoothedAmbientIntensity: CGFloat? // Smooth ambient intensity for lighting guidance
        let ambientIntensityEMAAlpha: CGFloat = 0.2 // Used for EMA this it our alpha value
        let tooDarkThreshold: CGFloat = 520 // 200 - 300 for dim rooms
        let tooDarkConsecutiveFramesThreshold = 12
        var tooDarkConsecutiveFrames = 0
        var isTooDark = false
        var lightingGuidePromotedIssue: ResolvedTrackingGuideIssue = .none

        enum PlacementGuideIssue: Equatable {
            case none
            case tooClose
            case findNearbySurface
        }

        enum ARKitGuideIssue: Equatable {
            case none
            case excessiveMotion
            case findNearbySurface
        }

        enum ResolvedTrackingGuideIssue: Equatable {
            case none
            case tooClose
            case excessiveMotion
            case findNearbySurface
            case tooDark
        }

        /// Placement guidance debounce state (`startUpdateLoop` / `.normal` path).
        var placementGuideDebounceIssue: PlacementGuideIssue = .none
        var placementGuideDebounceFrameCount: Int = 0
        var placementGuidePromotedIssue: PlacementGuideIssue = .none

        /// ARKit guidance debounce state (`.limited` / `.notAvailable` path).
        var arKitInsufficientFeaturesFrameCount: Int = 0
        var arKitNoneFrameCount: Int = 0
        let arKitInsufficientFeaturesShowThreshold = 8
        let arKitClearShowThreshold = 1

        var arKitGuidePromotedIssue: ARKitGuideIssue = .none


        // Custom motion detection (replace ARKit's excessive motion):
        /// Per-frame metric: displacement weight × translation (m) + rotation weight × angular delta (rad).
        let customExcessiveMotionThreshold: Float = 0.008
        /// Translation (m/frame) multiplied by this for `motionScore`; lower = more lenient on movement.
        let customExcessiveMotionDisplacementWeight: Float = 0.25
        /// Rotation (rad/frame) multiplied by this and added to translation for `motionScore`; tune on device (~0.05).
        let customExcessiveMotionRotationWeight: Float = 0.09
        var lastCameraTransform: simd_float4x4?
        var customExcessiveMotionFrameCount = 0
        let customExcessiveMotionShowThreshold = 2
        var customExcessiveMotionActive = false
        var customMotionPromotedIssue: ResolvedTrackingGuideIssue = .none // Add new property for custom motion (separate from ARKit's state)

        var flattenScanOccludesPlacementChrome = false

        /// Issue currently shown in the tracking guide banner.
        var displayedTrackingGuideIssue: ResolvedTrackingGuideIssue = .none
        var trackingGuideDisplayedAt: Date?
        static let trackingGuideMinimumDisplayDuration: TimeInterval = 2
        var trackingGuideTransitionWorkItem: DispatchWorkItem?

        var lastFlattenScanCornersReady = false

        /// Bumped to drop in-flight flatten scan completion work (e.g. user cancelled while processing).
        var flattenScanInvalidateGeneration: UInt64 = 0

        /// Captured `isEnabled` for flatten dual-snapshot capture (preview vs raw).
        struct FlattenScanSnapshotDecorationRestore {
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

        var flattenScanSnapshotDecorationRestore: FlattenScanSnapshotDecorationRestore?

        /// While true, the per-frame loop must not re-enable the ring between hiding it and `ARView.snapshot` completing.
        var isFlattenScanSnapshotCaptureActive = false

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
    static func makeWorldTrackingConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        return configuration
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        // We run our own ARWorldTrackingConfiguration (plane detection + LiDAR mesh). With the
        // default `true`, ARView can re-run its own default configuration when it enters the window,
        // silently replacing ours and changing what `raycastReticle` can hit.
        arView.automaticallyConfigureSession = false
        // Let RealityKit build collision shapes from the LiDAR scene mesh so `raycastReticle` can hit
        // object surfaces (box tops, etc.) directly instead of only ARKit-detected planes. Harmless on
        // devices without scene reconstruction (no mesh anchors → nothing to collide with).
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            arView.environment.sceneUnderstanding.options.insert(.collision)
        }

        context.coordinator.arView = arView
        context.coordinator.appliedTrackingGuideShowThreshold = trackingGuideShowThreshold
        context.coordinator.setupRingEntity(in: arView)
        context.coordinator.setupMeasurementEntities(in: arView)

        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingOverlay.goal = .anyPlane
        coachingOverlay.delegate = context.coordinator
        coachingOverlay.frame = arView.bounds
        arView.addSubview(coachingOverlay)
        context.coordinator.coachingOverlay = coachingOverlay

        arView.session.delegate = context.coordinator
        coachingOverlay.session = arView.session

        if isSessionPaused {
            context.coordinator.syncSessionPausedIfNeeded(true)
        } else {
            let configuration = Self.makeWorldTrackingConfiguration()
            arView.session.run(configuration)
            context.coordinator.startUpdateLoop()
        }

        DispatchQueue.main.async {
            context.coordinator.hasValidTarget = false
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.syncSessionPausedIfNeeded(isSessionPaused)
        context.coordinator.appliedMeasurementModeRaw = measurementModeRaw
        context.coordinator.appliedIdentifyDetections = identifyDetections
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
        isSessionPaused: false,
        isCoachingActive: .constant(false),
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
