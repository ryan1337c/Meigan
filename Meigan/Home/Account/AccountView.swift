//
//  AccountView.swift
//  Meigan
//
//  Account screen: plan summary, profile / security rows, and the subscription,
//  restore, and delete-account confirmation dialogs (see `AccountDialogs.swift`).
//

import SwiftUI
import StoreKit
import Supabase

struct AccountView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var subscriptions: SubscriptionManager

    @State private var showUpdatePaywall = false
    @State private var showCancelConfirmation = false
    @State private var showManageSubscriptions = false
    @State private var showPersonalInfoEditor = false
    @State private var showChangePassword = false
    @State private var showDeleteConfirmation = false
    @State private var deletionState: AccountDeletionSubscriptionState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(displayName)
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 8)

                yourPlanSection
                accountSection
                securitySection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPersonalInfoEditor) {
            EditPersonalInfoView()
        }
        .navigationDestination(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .fullScreenCover(isPresented: $showUpdatePaywall, onDismiss: {
            subscriptions.clearPurchaseError()
        }) {
            SubscriptionPaywallView(
                priceLabel: subscriptions.proPriceLabel,
                isPurchasing: subscriptions.isPurchasing,
                errorMessage: subscriptions.purchaseError,
                currentTier: subscriptions.currentTier,
                isRestoring: subscriptions.isRestoring,
                onRestore: {
                    Task {
                        await subscriptions.restorePurchases()
                        if subscriptions.currentTier == .pro {
                            showUpdatePaywall = false
                        }
                    }
                },
                onSkip: {
                    showUpdatePaywall = false
                },
                onSelectPro: {
                    Task {
                        await subscriptions.upgradeToPro()
                        if subscriptions.currentTier == .pro {
                            showUpdatePaywall = false
                        }
                    }
                }
            )
            .task { await subscriptions.loadProductsIfNeeded() }
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .onChange(of: showManageSubscriptions) { isPresented in
            guard !isPresented else { return }

            Task {
                await subscriptions.reconcileEntitlements()
            }
        }
        .overlay {
            if showCancelConfirmation {
                CancelPremiumDialog(
                    bullets: cancelDialogBullets,
                    onManage: {
                        showCancelConfirmation = false
                        showManageSubscriptions = true
                    },
                    onKeep: {
                        showCancelConfirmation = false
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .overlay {
            if let message = subscriptions.restoreMessage {
                RestoreResultDialog(
                    isSuccess: subscriptions.currentTier == .pro,
                    message: message,
                    onDone: { subscriptions.clearRestoreMessage() }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .overlay {
            if showDeleteConfirmation, let deletionState {
                DeleteAccountDialog(
                    state: deletionState,
                    onManage: {
                        showDeleteConfirmation = false
                        showManageSubscriptions = true
                    },
                    onDelete: {
                        showDeleteConfirmation = false
                        Task {
                            do {
                                try await appSession.deleteAccount()
                            } catch {
                                if case FunctionsError.httpError(let code, let data) = error {
                                    print("Delete account HTTP \(code):", String(data: data, encoding: .utf8) ?? "unknown")
                                }
                                throw error
                            }
                        }
                    },
                    onCancel: {
                        showDeleteConfirmation = false
                    }
                )
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCancelConfirmation)
        .animation(.easeInOut(duration: 0.2), value: subscriptions.restoreMessage)
        .animation(.easeInOut(duration: 0.2), value: showDeleteConfirmation)
    }

    // MARK: - Sections

    private var yourPlanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(UIColor.tertiarySystemFill))
                    )

                Label(planLabel, systemImage: "crown.fill")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(planDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )

            HStack(spacing: 12) {
                planActionButton(
                    title: "Update subscription",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    showUpdatePaywall = true
                }
                planActionButton(
                    title: "Cancel subscription",
                    systemImage: "xmark.circle"
                ) {
                    showCancelConfirmation = true
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            AccountRow(title: "Edit personal info", systemImage: "pencil") {
                showPersonalInfoEditor = true
            }
            Divider().padding(.leading, 56)
            AccountRow(title: "Edit card", systemImage: "creditcard") {
                // TODO: Navigate to payment method editor.
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Security and Privacy")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            AccountRow(title: "Change password", systemImage: "lock.shield") {
                showChangePassword = true
            }
            Divider().padding(.leading, 56)
            AccountRow(
                title: "Delete account",
                systemImage: "trash",
                isDestructive: true
            ) {
                Task {
                    deletionState = await subscriptions.accountDeletionState()
                    showDeleteConfirmation = true
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Derived copy

    private var displayName: String {
        let first = settings.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = settings.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = "\(first) \(last)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? "Guest" : combined
    }

    private var planLabel: String {
        subscriptions.currentTier == .pro ? "Premium" : "Free"
    }

    private var planDescription: String {
        subscriptions.currentTier == .pro
            ? "You are currently on the Pro plan."
            : "You are currently on the Free plan."
    }

    /// Concise cancellation points covering access retention, the effective
    /// expiry date, billing termination, data safety, and Apple billing.
    private var cancelDialogBullets: [CancelBullet] {
        let until: String
        if let date = subscriptions.proExpirationDate {
            until = date.formatted(date: .abbreviated, time: .omitted)
        } else {
            until = "the end of your billing cycle"
        }
        return [
            CancelBullet(
                symbol: "checkmark.seal",
                text: "Keep all Premium features until \(until)."
            ),
            CancelBullet(
                symbol: "creditcard",
                text: "You won't be charged again unless you resubscribe."
            ),
            CancelBullet(
                symbol: "lock.shield",
                text: "Your saved data and preferences stay safe."
            ),
            CancelBullet(
                symbol: "applelogo",
                text: "Subscriptions are managed through your Apple ID."
            ),
        ]
    }

    private func planActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct AccountRow: View {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(UIColor.tertiarySystemFill))
                    )

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundColor(isDestructive ? .red : .primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(isDestructive ? .red.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
    .environmentObject(SubscriptionManager())
}
