//
//  ARApplicationFooter.swift
//  Meigan
//
//  Bottom mode switcher (Ruler / Flatten / Identify) with Pro lock badges and the profile menu.
//

import SwiftUI

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

struct ARApplicationFooter: View {
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

            ProfileAvatarMenu(
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
