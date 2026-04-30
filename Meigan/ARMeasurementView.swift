import SwiftUI
import UIKit
import OSLog
import Photos

private let arMeasurementUILog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

enum ARFooterFeature: String {
    case ruler
    case flatten
}

struct ARMeasurementView: View {
    @AppStorage("hasSeenExplainer") private var hasSeenExplainer = false
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showExplainer = false
    @State private var showAccount = false
    @State private var showSettings = false
    @State private var isCoachingActive = true
    @State private var isRelocalizing = false
    @State private var hasValidTarget = false

    @State private var measurementReadout = "—"
    @State private var markCount = 0
    @State private var flattenSegmentCount = 0
    @State private var selectedFeature: ARFooterFeature = .ruler
    @State private var placeMarkToken = 0
    @State private var clearMarksToken = 0
    @State private var screenshotToken = 0
    @State private var screenshotPreviewImage: UIImage?
    @State private var showShareSheet = false
    @State private var shareSheetItems: [Any] = []
    @State private var placementWarningMessage = ""
    @State private var placementWarningToken = 0
    @State private var isARSessionActive = true

    // Simple trigger to recreate/reset the AR view
    @State private var arSessionResetID = UUID()

    var body: some View {
        Group {
            if showExplainer {
                ExplainerView(
                    onStart: {
                        hasSeenExplainer = true
                        showExplainer = false
                    }
                )
            } else {
                ZStack {
                    if isARSessionActive {
                        ARSceneView(
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
                            hapticFeedbackEnabled: $settings.hapticFeedbackEnabled,
                            placementWarningMessage: $placementWarningMessage,
                            placementWarningToken: $placementWarningToken
                        )
                        .id(arSessionResetID)
                    } else {
                        Color.black.ignoresSafeArea()
                    }

                    OverlaysView(
                        isCoachingActive: isCoachingActive,
                        isRelocalizing: isRelocalizing,
                        hasValidTarget: hasValidTarget,
                        selectedFeature: selectedFeature,
                        markCount: markCount,
                        flattenSegmentCount: flattenSegmentCount,
                        placementWarningMessage: placementWarningMessage,
                        profileInitial: profileInitial,
                        onStartScan: {
                            arMeasurementUILog.notice("Start Scan tapped")
                        },
                        onSelectFeature: { selectedFeature = $0 },
                        onScreenshot: {
                            screenshotToken += 1
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        },
                        onPlaceMark: {
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
                        }
                    )

                    if let preview = screenshotPreviewImage {
                        ScreenshotPreviewOverlay(
                            image: preview,
                            onDismiss: { screenshotPreviewImage = nil },
                            onSave: {
                                saveScreenshotToPhotoLibrary(preview) {
                                    screenshotPreviewImage = nil
                                }
                            },
                            onShare: {
                                shareSheetItems = [preview]
                                showShareSheet = true
                            }
                        )
                    }
                }
                .sheet(isPresented: $showShareSheet, onDismiss: { shareSheetItems = [] }) {
                    ActivityView(activityItems: shareSheetItems)
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
                        }
                    }
                }
            }
        }
        .onAppear {
            if !hasSeenExplainer {
                showExplainer = true
            }
            isARSessionActive = true
        }
        .onDisappear {
            isARSessionActive = false
            screenshotPreviewImage = nil
        }
        .onChange(of: scenePhase) { phase in
            isARSessionActive = (phase == .active) && !showAccount && !showSettings
        }
        .onChange(of: showAccount) { showing in
            if showing { isARSessionActive = false }
            else if scenePhase == .active && !showSettings { isARSessionActive = true }
        }
        .onChange(of: showSettings) { showing in
            if showing { isARSessionActive = false }
            else if scenePhase == .active && !showAccount { isARSessionActive = true }
        }
    }

    private var profileInitial: String {
        let first = settings.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let char = first.first {
            return String(char).uppercased()
        }
        return appSession.isGuest ? "G" : "?"
    }

    private func saveScreenshotToPhotoLibrary(_ image: UIImage, onSuccess: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    if success {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onSuccess()
                    }
                }
            }
        }
    }
}

// View for the explainer screen
private struct ExplainerView: View {
    let onStart: () -> Void // Called when user taps "Start Measuring"
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Centered content
            VStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                Text("Camera access needed")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Meigan uses your camera to measure distances in 3D space. iOS will ask for permission the first time you start measuring.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button {
                    onStart()
                } label: {
                    Text("Start AR Measurement")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.thinMaterial)
            .cornerRadius(20)
            .padding(.horizontal, 24)
        }
    }
}

private struct ScreenshotPreviewOverlay: View {
    let image: UIImage
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Screenshot")
                    .font(.headline)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 10) {
                    Button {
                        onShare()
                    } label: {
                        Text("Share")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onSave()
                    } label: {
                        Text("Save")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button("Done", action: onDismiss)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
            .padding(22)
            .background(.thinMaterial)
            .cornerRadius(20)
            .padding(.horizontal, 20)
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

// View for crosshair, buttons, etc.
private struct OverlaysView: View {
    let isCoachingActive: Bool
    let isRelocalizing: Bool
    let hasValidTarget: Bool
    let selectedFeature: ARFooterFeature
    let markCount: Int
    let flattenSegmentCount: Int
    let placementWarningMessage: String
    let profileInitial: String
    let onStartScan: () -> Void
    let onSelectFeature: (ARFooterFeature) -> Void
    let onScreenshot: () -> Void
    let onPlaceMark: () -> Void
    let onClearMarks: () -> Void
    let onAccount: () -> Void
    let onSettings: () -> Void
    let onLogOut: () -> Void

    private var hintText: String {
        if selectedFeature == .flatten {
            switch flattenSegmentCount {
            case 0:
                return "Flatten: aim and tap + for corner 1 of 4"
            case 1:
                return "Flatten: aim corner 3, triangle preview follows the crosshair"
            case 2:
                return "Flatten: aim corner 4, quad preview follows the crosshair"
            default:
                return "Flatten complete — tap Clear to restart"
            }
        }
        switch markCount {
        case 0:
            return "Aim crosshair, tap + for first point"
        case 1:
            return "Aim second point, tap +"
        default:
            return "Tap + for a new edge (lock to a pin to extend from it)"
        }
    }

    var body: some View {
        ZStack {
            if !isCoachingActive {
                if hasValidTarget {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                }

                VStack {
                    // Top controls
                    HStack {
                        Spacer()
                        Button("Clear") {
                            onClearMarks()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // Top status / hint
                    Text(hintText)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial)
                        .overlay(
                            Capsule()
                                .fill(Color.black.opacity(0.25))
                        )
                        .clipShape(Capsule())
                        .padding(.top, 4)

                    if !placementWarningMessage.isEmpty {
                        Text(placementWarningMessage)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.88))
                            .clipShape(Capsule())
                            .padding(.top, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()

                    VStack(spacing: 10) {
                        if selectedFeature == .flatten && flattenSegmentCount >= 3 {
                            Button {
                                onStartScan()
                            } label: {
                                Label("Start Scan", systemImage: "viewfinder")
                                    .font(.headline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.white)
                            .background(Color(red: 0.38, green: 0.58, blue: 0.92))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                        }

                        HStack(alignment: .center) {
                            Spacer()

                            Button {
                                onPlaceMark()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 80, weight: .regular))
                                    .frame(width: 100, height: 100)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canPlaceMark)
                            .opacity(canPlaceMark ? 1 : 0.45)

                            Spacer()
                        }
                        .overlay(alignment: .trailing) {
                            Button {
                                onScreenshot()
                            } label: {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .background(.thinMaterial)
                            .cornerRadius(20)
                            .padding(.trailing, 16)
                        }

                        ARApplicationFooter(
                            profileInitial: profileInitial,
                            selectedFeature: selectedFeature,
                            onSelectFeature: onSelectFeature,
                            onAccount: onAccount,
                            onSettings: onSettings,
                            onLogOut: onLogOut
                        )
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .foregroundColor(.white)
    }

    private var canPlaceMark: Bool {
        guard hasValidTarget else { return false }
        return true
    }
}

private struct ARApplicationFooter: View {
    let profileInitial: String
    let selectedFeature: ARFooterFeature
    let onSelectFeature: (ARFooterFeature) -> Void
    let onAccount: () -> Void
    let onSettings: () -> Void
    let onLogOut: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            footerFeatureButton(
                title: "Ruler",
                systemImage: "ruler",
                isSelected: selectedFeature == .ruler
            ) {
                onSelectFeature(.ruler)
            }
            .frame(maxWidth: .infinity)

            footerFeatureButton(
                title: "Flatten",
                systemImage: "level",
                isSelected: selectedFeature == .flatten
            ) {
                onSelectFeature(.flatten)
            }
            .frame(maxWidth: .infinity)

            ARProfileAvatarMenu(
                initial: profileInitial,
                onAccount: onAccount,
                onSettings: onSettings,
                onLogOut: onLogOut
            )
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func footerFeatureButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct ARProfileAvatarMenu: View {
    let initial: String
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
            Button(role: .destructive) { onLogOut() } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
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
