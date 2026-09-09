//
//  ARMeasurementBanners.swift
//  Meigan
//
//  Transient guidance chrome for the AR screen: top notice / guide banners and the
//  dimmed feature-lock prompt shown when a free or guest user taps a Pro mode.
//

import SwiftUI

/// Drives the paywall / sign-in overlay shown when a free or guest user taps a locked mode.
enum FeatureLockPrompt: Equatable, Identifiable {
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

/// Shown in the top guidance slot after the user saves an image to the photo library.
struct TopDownNoticeBanner: View {
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
struct OverlayGuideBanner: View {
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
struct FeatureLockOverlay: View {
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
