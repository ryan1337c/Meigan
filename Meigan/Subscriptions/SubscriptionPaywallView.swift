//
//  SubscriptionPaywallView.swift
//  Meigan
//
//  Post-registration paywall: pick Pro or continue for free.
//  Presentation only — purchase/skip behavior is injected via callbacks
//  so this view stays decoupled from StoreKit and Supabase.
//

import SwiftUI

struct SubscriptionPaywallView: View {
    /// Localized price label for the Pro plan (e.g. "$4.99 / year").
    /// Nil while the product is still loading.
    var priceLabel: String?
    var isPurchasing: Bool = false
    var errorMessage: String?
    var currentTier: SubscriptionTier = .free

    // Restore purchases
    var isRestoring: Bool = false
    let onRestore: () -> Void

    /// Called when the user chooses to continue on the free tier.
    let onSkip: () -> Void
    /// Called when the user picks the Pro plan.
    let onSelectPro: () -> Void

    private static let termsURL = URL(string: "https://meigan.app/terms")!
    private static let privacyURL = URL(string: "https://meigan.app/privacy")!
    private var isSelectedPlanActive: Bool { currentTier == .pro }

    struct FeatureItem {
        let symbol: String
        let title: String
        let detail: String
    }

    private let features: [FeatureItem] = [
        FeatureItem(symbol: "square.3.layers.3d.down.right", title: "Flatten Mode", detail: "Scan any surface and export a true-to-scale flattened image."),
        FeatureItem(symbol: "viewfinder.circle", title: "Identify Mode", detail: "Point your camera to detect and identify objects in real time."),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .secondarySystemBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        featureList
                        proPlanCard

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .background(Color.red)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("Measure more with Meigan Pro")
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Skip") {
                    onSkip()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .disabled(isPurchasing)
            }

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 56, height: 4)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(features, id: \.title) { feature in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundColor(.accentColor)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: feature.symbol)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.accentColor)
                            Text(feature.title)
                                .font(.body.weight(.semibold))
                        }
                        Text(feature.detail)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var proPlanCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRO")
                .font(.headline.weight(.bold))

            Text(priceLabel ?? "—")
                .font(.title3.weight(.bold))
                .redacted(reason: priceLabel == nil ? .placeholder : [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .padding(.top, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) {
            Text("FULL ACCESS")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor)
                )
                .offset(y: -12)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Button {
                guard !isSelectedPlanActive else { return }
                onSelectPro()
            } label: {
                Group {
                    if isSelectedPlanActive {
                        Text("Currently Active")
                            .font(.headline)
                    } else if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Continue with Pro")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.accentColor)
            .clipShape(Capsule())
            .disabled(isSelectedPlanActive || isPurchasing || priceLabel == nil)
            .opacity(isSelectedPlanActive || priceLabel == nil ? 0.5 : 1)

            Button("Restore Purchases") {
                onRestore()
            }
            .font(.subheadline.weight(.medium))
            .underline()
            .foregroundStyle(.secondary)
            .disabled(isPurchasing || isRestoring)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                Text("Cancel anytime. Secure with App Store.")
                    .font(.caption)
            }
            .foregroundColor(.secondary)

            Text("Our standard [Terms of Service](\(Self.termsURL)) apply. For more info on our data processing, please see our [Privacy Policy](\(Self.privacyURL)).")
                .font(.caption2)
                .foregroundColor(.secondary)
                .tint(.accentColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Previews

#Preview("Loaded") {
    SubscriptionPaywallView(
        priceLabel: "$4.99 / year",
        onRestore: {},
        onSkip: {},
        onSelectPro: {}
    )
}

#Preview("Loading price") {
    SubscriptionPaywallView(
        priceLabel: nil,
        onRestore: {},
        onSkip: {},
        onSelectPro: {}
    )
}

#Preview("Purchasing") {
    SubscriptionPaywallView(
        priceLabel: "$4.99 / year",
        isPurchasing: true,
        onRestore: {},
        onSkip: {},
        onSelectPro: {}
    )
}

#Preview("Currently Active") {
    SubscriptionPaywallView(
        priceLabel: "$4.99 / year",
        currentTier: .pro,
        onRestore: {},
        onSkip: {},
        onSelectPro: {}
    )
}

#Preview("Error") {
    SubscriptionPaywallView(
        priceLabel: "$4.99 / year",
        errorMessage: "Purchase failed. Please try again.",
        onRestore: {},
        onSkip: {},
        onSelectPro: {}
    )
}
