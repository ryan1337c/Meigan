//
//  ARMeasurementOverlaysView.swift
//  Meigan
//
//  Full-screen HUD layered over the AR scene: back button, guidance banners, crosshair,
//  place / clear / screenshot / scan controls, and the mode footer.
//

import SwiftUI
import UIKit

// View for crosshair, buttons, etc.
struct OverlaysView: View {
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
