//
//  ARMeasurementView.swift
//  Meigan
//
//  Root AR measurement screen: camera gate, ARSceneView bindings, feature lock / paywall
//  flow, and photo-library saving. Chrome lives in:
//  - `ARMeasurementOverlaysView.swift`: crosshair, banners, action buttons, footer host
//  - `ARApplicationFooter.swift`: mode switcher footer + `ARFooterFeature`
//  - `ARMeasurementBanners.swift`: notice / guide banners and the feature lock overlay
//  - `ARMeasurementPreviewOverlays.swift`: screenshot + scan preview overlays, share sheet
//  - `FlattenWarpResultInspectOverlay.swift`: flattened scan result inspector
//

import ARKit
import OSLog
import Photos
import SwiftUI
import UIKit

private let arMeasurementUILog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

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

#Preview {
    NavigationStack {
        ARMeasurementView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
    .environmentObject(SubscriptionManager())
}
