import SwiftUI
import UIKit
import OSLog
import Photos
import ARKit

private let arMeasurementUILog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

enum ARFooterFeature: String {
    case ruler
    case flatten
    case identify

    /// Pro-only modes. Ruler stays available on the free tier.
    var isProFeature: Bool {
        switch self {
        case .ruler:
            return false
        case .flatten, .identify:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .ruler:    return "Ruler"
        case .flatten:  return "Flatten"
        case .identify: return "Identify"
        }
    }
}

/// Drives the paywall / sign-in overlay shown when a free or guest user taps a locked mode.
private enum FeatureLockPrompt: Equatable, Identifiable {
    /// Signed-in free user — offer an upgrade to Pro.
    case upgrade(ARFooterFeature)
    /// Guest user — offer to sign in or create an account.
    case signIn(ARFooterFeature)

    var feature: ARFooterFeature {
        switch self {
        case .upgrade(let f), .signIn(let f):
            return f
        }
    }

    var id: String {
        switch self {
        case .upgrade(let f): return "upgrade-\(f.rawValue)"
        case .signIn(let f):  return "signIn-\(f.rawValue)"
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ARMeasurementView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var cameraGatePhase: CameraAccessGatePhase = CameraAccessGateResolver.resolve(
        status: SystemCameraAuthorizationService().status,
        isRequesting: false
    )
    @State private var isRequestingCameraAccess = false
    @State private var showAccount = false
    @State private var showSettings = false
    @State private var featureLockPrompt: FeatureLockPrompt?
    @State private var showUpgradePaywall = false
    @State private var isCoachingActive = false
    @State private var isRelocalizing = false
    @State private var hasValidTarget = false

    @State private var measurementReadout = "—"
    @State private var markCount = 0
    @State private var flattenSegmentCount = 0
    @State private var selectedFeature: ARFooterFeature = .ruler
    @State private var placeMarkToken = 0
    @State private var clearMarksToken = 0
    @State private var screenshotToken = 0
    @State private var flattenScanToken = 0
    @State private var screenshotPreviewImage: UIImage?
    @State private var flattenScanPreviewImage: UIImage?
    @State private var flattenScanResultImage: UIImage?
    @State private var flattenShapeFindings: [FlattenShapeFinding] = []
    @State private var flattenDetectionPreviewImage: UIImage?
    @State private var isFlattenScanActive = false
    @State private var flattenScanSigmas: [Float] = []
    @State private var flattenScanCornersReady = false
    @State private var sharePayload: SharePayload?
    @State private var placementWarningMessage = ""
    @State private var placementWarningToken = 0
    @State private var placementBannerKind: PlacementBannerKind = .alert
    @State private var photoSavedBannerMessage: String?
    @State private var photoSavedBannerDismissToken = 0
    @State private var flattenRelocationActive = false
    @State private var flattenFooterHeight: CGFloat = 0
    @State private var isARSessionActive = true
    /// Consecutive `.limited` frames before showing the tracking guide (~6 ≈ 100 ms at 60 fps).
    @State private var trackingGuideShowThreshold = 6
    @State private var activeTrackingReason: ARCamera.TrackingState.Reason? = nil
    @State private var trackingGuideMessage: String = ""
    @State private var trackingGuideKind: PlacementBannerKind = .instruction
    @State private var identifyDetections: [IdentifyDetection] = []

    // Simple trigger to recreate/reset the AR view
    @State private var arSessionResetID = UUID()

    private let cameraAuthorization: any CameraAuthorizing = SystemCameraAuthorizationService()

    private var hasPinnedMeasurementPoints: Bool {
        switch selectedFeature {
        case .ruler:
            return markCount > 0
        case .flatten:
            return flattenSegmentCount > 0
        case .identify:
            return false
        }
    }

    private var isPro: Bool {
        subscriptions.currentTier == .pro
    }

    /// Modes the user can't enter yet (Pro features while on the free tier).
    private var lockedFeatures: Set<ARFooterFeature> {
        isPro ? [] : [.flatten, .identify]
    }

    /// Settings, account, and feature-lock flows pause ARKit in place (no remount).
    private var blocksARSession: Bool {
        showAccount || showSettings || featureLockPrompt != nil
    }

    private func refreshARSessionActive() {
        // Allow AR while `.inactive` (e.g. right after the camera permission sheet dismisses).
        // Dismount only when the app is fully backgrounded; overlays pause via `isSessionPaused`.
        isARSessionActive = cameraGatePhase == .ready
            && scenePhase != .background
    }

    private func refreshCameraGate() {
        cameraGatePhase = CameraAccessGateResolver.resolve(
            status: cameraAuthorization.status,
            isRequesting: isRequestingCameraAccess
        )
        refreshARSessionActive()
    }

    private func requestCameraAccess() {
        guard !isRequestingCameraAccess else { return }
        isRequestingCameraAccess = true
        cameraGatePhase = .requesting

        Task {
            let granted = await cameraAuthorization.requestAccess()
            isRequestingCameraAccess = false
            cameraGatePhase = granted ? .ready : .denied
            refreshARSessionActive()
        }
    }

    private func openCameraSettings() {
        cameraAuthorization.openAppSettings()
    }

    /// Routes a tap on a locked mode to the right prompt (guest → sign in, free → upgrade).
    private func handleLockedFeatureTap(_ feature: ARFooterFeature) {
        featureLockPrompt = appSession.isGuest ? .signIn(feature) : .upgrade(feature)
    }

    var body: some View {
        Group {
            if cameraGatePhase != .ready {
                CameraAccessGateView(
                    phase: cameraGatePhase,
                    onRequestAccess: requestCameraAccess,
                    onOpenSettings: openCameraSettings,
                    onGoBack: { dismiss() }
                )
            } else {
                ZStack {
                    if isARSessionActive {
                        ARSceneView(
                            isSessionPaused: blocksARSession,
                            isCoachingActive: $isCoachingActive,
                            isRelocalizing: $isRelocalizing,
                            hasValidTarget: $hasValidTarget,
                            measurementReadout: $measurementReadout,
                            markCount: $markCount,
                            flattenSegmentCount: $flattenSegmentCount,
                            measurementModeRaw: Binding(
                                get: { selectedFeature.rawValue },
                                set: { selectedFeature = ARFooterFeature(rawValue: $0) ?? .ruler }
                            ),
                            measurementUnitRaw: $settings.measurementUnit,
                            placeMarkToken: $placeMarkToken,
                            clearMarksToken: $clearMarksToken,
                            screenshotToken: $screenshotToken,
                            screenshotPreviewImage: $screenshotPreviewImage,
                            flattenScanToken: $flattenScanToken,
                            flattenScanPreviewImage: $flattenScanPreviewImage,
                            flattenScanResultImage: $flattenScanResultImage,
                            flattenShapeFindings: $flattenShapeFindings,
                            flattenDetectionPreviewImage: $flattenDetectionPreviewImage,
                            isFlattenScanActive: $isFlattenScanActive,
                            flattenScanSigmas: $flattenScanSigmas,
                            flattenScanCornersReady: $flattenScanCornersReady,
                            hapticFeedbackEnabled: $settings.hapticFeedbackEnabled,
                            placementWarningMessage: $placementWarningMessage,
                            placementWarningToken: $placementWarningToken,
                            placementBannerKind: $placementBannerKind,
                            flattenRelocationActive: $flattenRelocationActive,
                            flattenFooterHeight: $flattenFooterHeight,
                            trackingGuideShowThreshold: trackingGuideShowThreshold,
                            activeTrackingReason: $activeTrackingReason,
                            trackingGuideMessage: $trackingGuideMessage,
                            trackingGuideKind: $trackingGuideKind,
                            identifyDetections: $identifyDetections
                        )
                        .id(arSessionResetID)
                    } else {
                        Color.black.ignoresSafeArea()
                    }

                    if selectedFeature == .identify, !isCoachingActive {
                        IdentifyAnnotationOverlay(detections: identifyDetections)
                    }

                    OverlaysView(
                        isCoachingActive: isCoachingActive,
                        isRelocalizing: isRelocalizing,
                        hasValidTarget: hasValidTarget,
                        selectedFeature: selectedFeature,
                        flattenSegmentCount: flattenSegmentCount,
                        flattenRelocationActive: flattenRelocationActive,
                        flattenScanCornersReady: flattenScanCornersReady,
                        isFlattenScanActive: isFlattenScanActive,
                        placementWarningMessage: placementWarningMessage,
                        placementBannerKind: placementBannerKind,
                        trackingGuideMessage: trackingGuideMessage,
                        trackingGuideKind: trackingGuideKind,
                        photoSavedBannerMessage: photoSavedBannerMessage,
                        profileInitial: profileInitial,
                        isGuest: appSession.isGuest,
                        hasPinnedPoints: hasPinnedMeasurementPoints,
                        lockedFeatures: lockedFeatures,
                        onBack: { dismiss() },
                        onStartScan: {
                            flattenScanToken += 1
                            arMeasurementUILog.notice("Start Scan tapped")
                        },
                        onSelectFeature: { feature in
                            if lockedFeatures.contains(feature) {
                                handleLockedFeatureTap(feature)
                            } else {
                                selectedFeature = feature
                            }
                        },
                        onScreenshot: {
                            guard trackingGuideMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            guard !isFlattenScanActive else { return }
                            screenshotToken += 1
                        },
                        onPlaceMark: {
                            guard trackingGuideMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            guard !isFlattenScanActive else { return }
                            guard hasValidTarget else {
                                arMeasurementUILog.warning("onPlaceMark: ignored (hasValidTarget=false)")
                                return
                            }
                            placeMarkToken += 1
                            arMeasurementUILog.notice("onPlaceMark: placeMarkToken=\(placeMarkToken) after increment")
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        },
                        onClearMarks: {
                            clearMarksToken += 1
                            measurementReadout = "—"
                            markCount = 0
                        },
                        onAccount: {
                            showAccount = true
                        },
                        onSettings: {
                            showSettings = true
                        },
                        onLogOut: {
                            appSession.logOut()
                        },
                        onFooterHeightChange: { height in
                            let clamped = max(0, height)
                            guard abs(clamped - flattenFooterHeight) > 0.5 else { return }
                            flattenFooterHeight = clamped
                        }
                    )

                    if let preview = screenshotPreviewImage {
                        ScreenshotPreviewOverlay(
                            image: preview,
                            onDismiss: { screenshotPreviewImage = nil },
                            onSave: {
                                saveScreenshotToPhotoLibrary(preview) { success in
                                    if success {
                                        screenshotPreviewImage = nil
                                    }
                                }
                            },
                            onShare: {
                                sharePayload = SharePayload(image: preview)
                            }
                        )
                    }

                    if isFlattenScanActive {
                        FlattenScanPreviewOverlay(image: flattenScanPreviewImage)
                    }

                    if let result = flattenScanResultImage, !isFlattenScanActive {
                        FlattenWarpResultInspectOverlay(
                            image: result,
                            findings: flattenShapeFindings,
                            detectionPreviewImage: flattenDetectionPreviewImage,
                            measurementUnit: MeasurementUnit.from(storage: settings.measurementUnit),
                            photoSavedBannerMessage: photoSavedBannerMessage,
                            onDismiss: {
                                flattenScanResultImage = nil
                                flattenShapeFindings = []
                                flattenDetectionPreviewImage = nil
                            },
                            onSave: { exportImage in
                                saveScreenshotToPhotoLibrary(exportImage) { success in
                                    if success {
                                        flattenScanResultImage = nil
                                        flattenShapeFindings = []
                                        flattenDetectionPreviewImage = nil
                                    }
                                }
                            },
                            onShare: { exportImage in
                                sharePayload = SharePayload(image: exportImage)
                            },
                            onSaveDetectionPreview: { previewImage, completion in
                                saveScreenshotToPhotoLibrary(previewImage) { success in
                                    completion(success)
                                }
                            }
                        )
                    }

                    if let prompt = featureLockPrompt {
                        FeatureLockOverlay(
                            prompt: prompt,
                            priceLabel: subscriptions.proPriceLabel,
                            onPrimaryAction: {
                                switch prompt {
                                case .upgrade:
                                    showUpgradePaywall = true
                                case .signIn:
                                    featureLockPrompt = nil
                                    appSession.logOut()
                                }
                            },
                            onDismiss: { featureLockPrompt = nil }
                        )
                        .transition(.opacity)
                        .zIndex(10)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: featureLockPrompt)
                .fullScreenCover(isPresented: $showUpgradePaywall, onDismiss: {
                    subscriptions.clearPurchaseError()
                }) {
                    SubscriptionPaywallView(
                        priceLabel: subscriptions.proPriceLabel,
                        isPurchasing: subscriptions.isPurchasing,
                        errorMessage: subscriptions.purchaseError,
                        currentTier: subscriptions.currentTier,
                        isRestoring: subscriptions.isRestoring,
                        onRestore: {
                            Task { await subscriptions.restorePurchases() }
                        },
                        onSkip: {
                            showUpgradePaywall = false
                            featureLockPrompt = nil
                        },
                        onSelectPro: {
                            Task { await subscriptions.upgradeToPro() }
                        }
                    )
                    .task { await subscriptions.loadProductsIfNeeded() }
                }
                .sheet(item: $sharePayload) { payload in
                    ActivityView(activityItems: [payload.image])
                }
                .navigationDestination(isPresented: $showAccount) {
                    AccountView()
                }
                .navigationDestination(isPresented: $showSettings) {
                    SettingsView()
                }
                .onChange(of: placementWarningToken) { token in
                    guard token > 0 else { return }
                    let currentToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        if placementWarningToken == currentToken {
                            placementWarningMessage = ""
                            placementBannerKind = .alert
                        }
                    }
                }
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .onAppear {
            refreshCameraGate()
        }
        .onDisappear {
            isARSessionActive = false
            screenshotPreviewImage = nil
            flattenScanPreviewImage = nil
            flattenScanResultImage = nil
            flattenShapeFindings = []
            flattenDetectionPreviewImage = nil
            isFlattenScanActive = false
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                refreshCameraGate()
            } else {
                refreshARSessionActive()
            }
        }
        .onChange(of: showAccount) { _ in
            refreshARSessionActive()
        }
        .onChange(of: showSettings) { _ in
            refreshARSessionActive()
        }
        .onChange(of: featureLockPrompt) { _ in
            refreshARSessionActive()
        }
        .onChange(of: subscriptions.currentTier) { tier in
            // Purchase completed (here or via the full paywall) — unlock and resume.
            if tier == .pro {
                showUpgradePaywall = false
                featureLockPrompt = nil
            }
            else if tier == .free {
                // If the user is on the free tier and the selected feature is a pro feature, show the feature lock prompt
                // and navigate user back to ruler
                if selectedFeature.isProFeature {
                    let lockedFeature = selectedFeature
                    isFlattenScanActive = false
                    selectedFeature = .ruler
                    featureLockPrompt = .upgrade(lockedFeature)
                }
            }
        }
        .onChange(of: isCoachingActive) { active in
            if active {
                identifyDetections = []
            }
        }
    }

    private var profileInitial: String {
        let first = settings.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let char = first.first {
            return String(char).uppercased()
        }
        return appSession.isGuest ? "G" : "?"
    }

    private func presentPhotoSavedBanner() {
        photoSavedBannerMessage = "Saved to Photos"
        photoSavedBannerDismissToken += 1
        let dismissToken = photoSavedBannerDismissToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if photoSavedBannerDismissToken == dismissToken {
                photoSavedBannerMessage = nil
            }
        }
    }

    /// Shared by AR screenshot preview and flatten scan result — banner + haptic only after a successful library save.
    private func saveScreenshotToPhotoLibrary(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    guard success else {
                        completion(false)
                        return
                    }
                    completion(true)
                    if settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    presentPhotoSavedBanner()
                }
            }
        }
    }
}

private struct ScreenshotPreviewOverlay: View {
    var title = "Screenshot"
    /// When non-nil, caps image height (points). When nil, the image can use the full screen.
    var imageMaxHeight: CGFloat?
    let image: UIImage
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        GeometryReader { geo in
            let imageHeight = min(geo.size.height, imageMaxHeight ?? .infinity)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    ZStack {
                        Text(title)
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
                                Button(action: onSave) {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }

                                Button(action: onShare) {
                                    Label("Share", systemImage: "square.and.arrow.up")
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
                            .accessibilityLabel("Screenshot actions")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, geo.safeAreaInsets.top + 12)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)

                    Spacer()
                        .allowsHitTesting(false)
                }
                .foregroundStyle(.white)
            }
            .ignoresSafeArea()
        }
    }
}

/// Sheet showing the grayscale bitmap passed to `VNDetectContoursRequest`.
private struct FlattenDetectionPreviewSheet: View {
    let image: UIImage
    let onSave: (@escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var showsSaveError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This is the mono + contrast + median image Vision uses for contour detection. If the object boundary is faint or broken here, tuning contrast alone won’t fix bounding boxes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("Vision Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !isSaving else { return }
                        isSaving = true
                        onSave { success in
                            isSaving = false
                            if success {
                                dismiss()
                            } else {
                                showsSaveError = true
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save to Photos")
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .alert("Unable to Save Photo", isPresented: $showsSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check Meigan's Photos access in Settings, then try again.")
            }
        }
    }
}

struct IdentifyAnnotationOverlay: View {
    let detections: [IdentifyDetection]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(detections) { d in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.green, lineWidth: 2)
                        .frame(width: d.viewRect.width, height: d.viewRect.height)

                    Text("\(d.label) \(Int(d.confidence * 100))%")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green, ignoresSafeAreaEdges: [])
                        .foregroundColor(.black)
                        .offset(y: -16)
                }
                .position(x: d.viewRect.midX, y: d.viewRect.midY)
            }
        }
        .allowsHitTesting(false)   // so footer/buttons stay tappable
        .ignoresSafeArea()         // match arView.bounds full-screen coords
    }
}

/// Full-color warped result with SwiftUI vector box strokes aligned to `scaledToFit` letterboxing; tap maps to image pixels (smallest clipped bbox wins on overlap).
private struct FlattenWarpResultInspectOverlay: View {
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

private struct FlattenScanPreviewOverlay: View {
    let image: UIImage?
    @State private var scanOffset: CGFloat = -0.45

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let edgeMargin: CGFloat = 16
            let maxCardWidth = min(proxy.size.width - edgeMargin * 2, 460)
            let safeHeight = proxy.size.height - insets.top - insets.bottom
            /// Title + subtitle + `VStack` spacing + card padding — keep preview within visible safe band.
            let verticalChrome: CGFloat = 152
            let previewWidth = max(1, maxCardWidth - 36)
            let previewHeight = min(
                previewWidth * 0.92,
                max(120, safeHeight * 0.88 - verticalChrome)
            )

            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(spacing: 12) {
                        Text("Scanning surface")
                            .font(.headline.weight(.semibold))
                            .multilineTextAlignment(.center)

                        ZStack {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: previewWidth, height: previewHeight)
                                    .clipped()
                                    .transition(.opacity)
                            } else {
                                // Snapshot not yet ready — keep the chrome visible so the user
                                // sees instant feedback the moment they tap Start Scan.
                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.55),
                                        Color.black.opacity(0.35)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(width: previewWidth, height: previewHeight)
                            }

                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.cyan.opacity(0.22),
                                    Color.white.opacity(0.92),
                                    Color.cyan.opacity(0.22),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: min(40, previewHeight * 0.22))
                            .offset(y: scanOffset * previewHeight)
                            .shadow(color: .cyan.opacity(0.55), radius: 14)
                        }
                        .frame(width: previewWidth, height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        )

                        Text("Analyzing plane geometry…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .frame(width: maxCardWidth)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, edgeMargin)
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                scanOffset = -0.45
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    scanOffset = 0.45
                }
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Shown in the top guidance slot after the user saves an image to the photo library.
private struct TopDownNoticeBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
            Text(message)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            Capsule()
                .fill(Color(red: 0.18, green: 0.55, blue: 0.34).opacity(0.94))
        )
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        }
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }
}

/// Capsule below the primary hint — same layout and styling for AR-driven placement messages (`.instruction` / `.alert`) and SwiftUI-only guides that swap in the same slot.
private struct OverlayGuideBanner: View {
    let text: String
    let kind: PlacementBannerKind

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if !trimmed.isEmpty {
                Text(trimmed)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(kind == .instruction ? Color.white.opacity(0.92) : Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(kind == .instruction ? Color.black.opacity(0.42) : Color.red.opacity(0.88))
                    )
                    .overlay {
                        if kind == .instruction {
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

/// Paywall / sign-in card shown over the AR screen when a free or guest user taps a locked mode.
/// The AR session is torn down by the parent while this is visible, so nothing renders behind it.
private struct FeatureLockOverlay: View {
    let prompt: FeatureLockPrompt
    let priceLabel: String?
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    private var isGuestPrompt: Bool {
        if case .signIn = prompt { return true }
        return false
    }

    private var title: String {
        isGuestPrompt ? "Sign in to unlock" : "Upgrade to PRO"
    }

    private var message: String {
        let feature = prompt.feature.displayName
        if isGuestPrompt {
            return "\(feature) Mode is part of Meigan Pro. Sign in or create an account to upgrade and unlock it."
        }
        return "\(feature) Mode is a Pro feature. Right now you are on a free plan — upgrade for access."
    }

    private var primaryTitle: String {
        isGuestPrompt ? "Sign In or Create Account" : "Upgrade to PRO"
    }

    private var secondaryTitle: String {
        isGuestPrompt ? "Not now" : "Not today"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 20) {
                badge

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !isGuestPrompt, let priceLabel {
                    Text(priceLabel)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 10) {
                    Button(action: onPrimaryAction) {
                        Text(primaryTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .clipShape(Capsule())

                    Button(action: onDismiss) {
                        Text(secondaryTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .foregroundColor(.accentColor)
                    .background(
                        Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
            .padding(.horizontal, 28)
        }
        .foregroundColor(.primary)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 96, height: 96)

            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)

            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
                .overlay(
                    Circle().strokeBorder(Color(.secondarySystemBackground), lineWidth: 2.5)
                )
                .offset(x: 33, y: 33)
        }
        .padding(.top, 4)
    }
}

// View for crosshair, buttons, etc.
private struct OverlaysView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let isCoachingActive: Bool
    let isRelocalizing: Bool
    let hasValidTarget: Bool
    let selectedFeature: ARFooterFeature
    let flattenSegmentCount: Int
    let flattenRelocationActive: Bool
    let flattenScanCornersReady: Bool
    let isFlattenScanActive: Bool
    let placementWarningMessage: String
    let placementBannerKind: PlacementBannerKind
    let trackingGuideMessage: String
    let trackingGuideKind: PlacementBannerKind
    /// When set, top guidance is hidden and this banner occupies that slot (e.g. after Save to Photos).
    let photoSavedBannerMessage: String?
    let profileInitial: String
    let isGuest: Bool
    let hasPinnedPoints: Bool
    let lockedFeatures: Set<ARFooterFeature>
    let onBack: () -> Void
    let onStartScan: () -> Void
    let onSelectFeature: (ARFooterFeature) -> Void
    let onScreenshot: () -> Void
    let onPlaceMark: () -> Void
    let onClearMarks: () -> Void
    let onAccount: () -> Void
    let onSettings: () -> Void
    let onLogOut: () -> Void
    let onFooterHeightChange: (CGFloat) -> Void

    private var trackingGuideActive: Bool {
        !trackingGuideMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesSideActionLayout: Bool {
        if horizontalSizeClass == .regular {
            return true
        }
        let screenBounds = UIScreen.main.bounds
        return min(screenBounds.width, screenBounds.height) >= 700
    }

    private var hintText: String {
        if selectedFeature == .identify {
            return ""
        }
        if selectedFeature == .flatten && flattenRelocationActive {
            return "Corner selected, move to re adjust"
        }
        if selectedFeature == .flatten {
            guard flattenSegmentCount < 4 else { return "" }
            return "Add point (\(flattenSegmentCount + 1)/4)"
        }
        return "Add a point"
    }

    private var trimmedHintText: String {
        hintText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same capsule as coordinator `showPlacementWarning(..., .instruction)` messages (“Corner …”, “All 4 corners…”).
    private var secondaryGuideText: String {
        guard !isFlattenScanActive else { return "" }
        if trackingGuideActive {
            return trackingGuideMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !placementWarningMessage.isEmpty {
            return placementWarningMessage
        }
        if selectedFeature == .flatten,
           flattenSegmentCount >= 3,
           !flattenRelocationActive,
           !flattenScanCornersReady {
            return Self.scanCornersUnavailableGuide
        }
        return ""
    }

    private var secondaryGuideKind: PlacementBannerKind {
        if trackingGuideActive {
            return trackingGuideKind
        }
        if !placementWarningMessage.isEmpty {
            return placementBannerKind
        }
        return .instruction
    }

    private static let scanCornersUnavailableGuide =
        "Start Scan is unavailable until all four corner marks appear inside the frame."

    /// Drives ease-in (no ease-out) when hint / tracking / placement secondary copy changes.
    private var guidanceAnimationSignature: String {
        let sec = secondaryGuideText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(isFlattenScanActive)|\(trackingGuideActive)|\(trimmedHintText)|\(sec)|\(String(describing: secondaryGuideKind))"
    }

    var body: some View {
        ZStack {
            if !isCoachingActive {
                if selectedFeature != .identify,
                   hasValidTarget, !trackingGuideActive, !isFlattenScanActive {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                }

                VStack(spacing: 0) {
                    // Top controls
                    HStack {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "arrow.backward")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 46, minHeight: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isFlattenScanActive)
                        .opacity(isFlattenScanActive ? 0.45 : 1)
                        .accessibilityLabel("Back")

                        Spacer()

                        Button {
                            onClearMarks()
                        } label: {
                            Text("Clear")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(hasPinnedPoints ? Color.white : Color.white.opacity(0.4))
                                .animation(.easeInOut(duration: 0.28), value: hasPinnedPoints)
                                .frame(minWidth: 56, minHeight: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isFlattenScanActive)
                        .opacity(isFlattenScanActive ? 0.45 : 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 22)

                    if isFlattenScanActive {
                        Color.clear
                            .frame(height: 1)
                            .padding(.top, 4)
                    } else if let savedMessage = photoSavedBannerMessage {
                        TopDownNoticeBanner(message: savedMessage)
                            .padding(.top, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        VStack(spacing: 6) {
                            if !trackingGuideActive, !isFlattenScanActive, !trimmedHintText.isEmpty {
                                Text(hintText)
                                    .font(.callout.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.thinMaterial)
                                    .overlay(
                                        Capsule()
                                            .fill(Color.black.opacity(0.25))
                                    )
                                    .clipShape(Capsule())
                                    .padding(.top, 4)
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }

                            OverlayGuideBanner(text: secondaryGuideText, kind: secondaryGuideKind)
                        }
                        .animation(.easeIn(duration: 0.14), value: guidanceAnimationSignature)
                    }

                    Spacer()

                    VStack(spacing: 10) {
                        if usesSideActionLayout {
                            if showsStartScanButton {
                                HStack {
                                    Spacer()
                                    startScanButton
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                            }
                        } else {
                            HStack(alignment: .center) {
                                Spacer()
                                placeMarkButton

                                if showsStartScanButton {
                                    Spacer()
                                    startScanButton
                                }

                                Spacer()
                                screenshotButton
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ARApplicationFooter(
                        profileInitial: profileInitial,
                        isGuest: isGuest,
                        selectedFeature: selectedFeature,
                        lockedFeatures: lockedFeatures,
                        interactionLockedDuringFlattenScan: isFlattenScanActive,
                        onSelectFeature: onSelectFeature,
                        onAccount: onAccount,
                        onSettings: onSettings,
                        onLogOut: onLogOut
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ARFooterHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .background {
                        Rectangle()
                        .fill(Color.black.opacity(0.78))
                        .ignoresSafeArea(edges: [.horizontal, .bottom])
                    }
                }

                if usesSideActionLayout {
                    VStack(spacing: 16) {
                        screenshotButton
                        placeMarkButton
                    }
                    .padding(.trailing, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
        }
        .foregroundColor(.white)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: photoSavedBannerMessage)
        .onPreferenceChange(ARFooterHeightPreferenceKey.self, perform: onFooterHeightChange)
    }

    private var showsStartScanButton: Bool {
        selectedFeature == .flatten && flattenSegmentCount >= 3 && !flattenRelocationActive
    }

    @ViewBuilder
    private var placeMarkButton: some View {
        if selectedFeature != .identify {
            Button {
                onPlaceMark()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 80, weight: .regular))
                    .frame(width: 100, height: 100)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlaceMark)
            .opacity(canPlaceMark ? 1 : 0.45)
        }
    }

    private var screenshotButton: some View {
        Button {
            onScreenshot()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(trackingGuideActive || isFlattenScanActive)
        .opacity((trackingGuideActive || isFlattenScanActive) ? 0.45 : 1)
        .padding(10)
        .background(.thinMaterial)
        .cornerRadius(20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var startScanButton: some View {
        Button {
            onStartScan()
        } label: {
            Label("Start Scan", systemImage: "viewfinder")
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .background(
            flattenScanCornersReady
                ? Color(red: 0.38, green: 0.58, blue: 0.92)
                : Color.white.opacity(0.22)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(flattenScanCornersReady ? 0 : 0.35), lineWidth: 1)
        )
        .disabled(!flattenScanCornersReady || isFlattenScanActive)
        .opacity(
            flattenScanCornersReady && !isFlattenScanActive ? 1 : 0.72
        )
    }

    private var canPlaceMark: Bool {
        guard selectedFeature != .identify else { return false }
        guard hasValidTarget, !trackingGuideActive, !isFlattenScanActive else { return false }
        return true
    }
}

private struct ARFooterHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ARApplicationFooter: View {
    let profileInitial: String
    let isGuest: Bool
    let selectedFeature: ARFooterFeature
    let lockedFeatures: Set<ARFooterFeature>
    let interactionLockedDuringFlattenScan: Bool
    let onSelectFeature: (ARFooterFeature) -> Void
    let onAccount: () -> Void
    let onSettings: () -> Void
    let onLogOut: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            footerFeatureButton(
                title: "Ruler",
                systemImage: "ruler",
                isSelected: selectedFeature == .ruler,
                isLocked: lockedFeatures.contains(.ruler)
            ) {
                onSelectFeature(.ruler)
            }
            .frame(maxWidth: .infinity)
            .disabled(interactionLockedDuringFlattenScan)
            .opacity(interactionLockedDuringFlattenScan ? 0.45 : 1)

            footerFeatureButton(
                title: "Flatten",
                systemImage: "level",
                isSelected: selectedFeature == .flatten,
                isLocked: lockedFeatures.contains(.flatten)
            ) {
                onSelectFeature(.flatten)
            }
            .frame(maxWidth: .infinity)
            .disabled(interactionLockedDuringFlattenScan)
            .opacity(interactionLockedDuringFlattenScan ? 0.45 : 1)

            footerFeatureButton(
                title: "Identify",
                systemImage: "viewfinder.circle",
                isSelected: selectedFeature == .identify,
                isLocked: lockedFeatures.contains(.identify)
            ) {
                onSelectFeature(.identify)
            }
            .frame(maxWidth: .infinity)
            .disabled(interactionLockedDuringFlattenScan)
            .opacity(interactionLockedDuringFlattenScan ? 0.45 : 1)

            ARProfileAvatarMenu(
                initial: profileInitial,
                isGuest: isGuest,
                onAccount: onAccount,
                onSettings: onSettings,
                onLogOut: onLogOut
            )
            .disabled(interactionLockedDuringFlattenScan)
            .opacity(interactionLockedDuringFlattenScan ? 0.45 : 1)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func footerFeatureButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        isLocked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if isLocked {
                            FooterLockBadge()
                                .offset(x: 11, y: -7)
                        }
                    }
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(featureTint(isSelected: isSelected, isLocked: isLocked))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(isLocked ? "\(title), Pro feature, locked" : title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func featureTint(isSelected: Bool, isLocked: Bool) -> Color {
        if isSelected {
            return .white
        }
        return isLocked ? .white.opacity(0.5) : .white.opacity(0.72)
    }
}

/// Small lock pip pinned to the top-trailing of a locked footer mode icon.
private struct FooterLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .background(
                Circle().fill(Color.accentColor)
            )
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

private struct ARProfileAvatarMenu: View {
    let initial: String
    let isGuest: Bool
    let onAccount: () -> Void
    let onSettings: () -> Void
    let onLogOut: () -> Void

    var body: some View {
        Menu {
            Button { onAccount() } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
            Button { onSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            if isGuest {
                Button { onLogOut() } label: {
                    Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                }
                .tint(.accentColor)
            } else {
                Button(role: .destructive) { onLogOut() } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(white: 0.18))
                    .frame(width: 40, height: 40)

                Circle()
                    .fill(Color(red: 0.38, green: 0.58, blue: 0.92))
                    .frame(width: 28, height: 28)

                Text(initial)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ARMeasurementView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
    .environmentObject(SubscriptionManager())
}
