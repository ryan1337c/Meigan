//
//  AccountDialogs.swift
//  Meigan
//
//  Centered, dimmed-overlay confirmation dialogs presented from `AccountView`.
//

import SwiftUI

// MARK: - Cancel Premium Dialog

struct CancelBullet: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

/// Confirmation shown when the user taps "Cancel subscription". Lays out the
/// cancellation details as vertically stacked bullet points instead of a single
/// cluttered paragraph.
struct CancelPremiumDialog: View {
    let bullets: [CancelBullet]
    let onManage: () -> Void
    let onKeep: () -> Void

    var body: some View {
        DialogScrim(onTapOutside: onKeep) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                Text("Cancel Premium?")
                    .font(.title2.weight(.bold))
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(bullets) { bullet in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: bullet.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 22)
                        Text(bullet.text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            VStack(spacing: 10) {
                Button(action: onManage) {
                    Text("Manage Subscription")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onKeep) {
                    Text("Keep Premium")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Restore Result Dialog

/// Confirmation shown after "Restore Purchases". Icon and accent adapt to
/// whether an active subscription was found.
struct RestoreResultDialog: View {
    let isSuccess: Bool
    let message: String
    let onDone: () -> Void

    var body: some View {
        DialogScrim(onTapOutside: onDone) {
            VStack(spacing: 8) {
                Image(systemName: isSuccess ? "checkmark.seal.fill" : "info.circle.fill")
                    .font(.title)
                    .foregroundColor(isSuccess ? .accentColor : .secondary)
                Text(isSuccess ? "Purchases Restored" : "No Subscription Found")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
            }

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onDone) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Delete Account Dialog

/// Confirmation shown when the user taps "Delete account". The warning copy —
/// and whether a "Manage Subscriptions" button is offered — adapts to the user's
/// subscription state so we only surface the Apple-required billing warning
/// when a still-renewing subscription exists.
struct DeleteAccountDialog: View {
    let state: AccountDeletionSubscriptionState
    let onManage: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var message: String {
        switch state {
        case .free:
            return "Are you sure you want to delete your account? All of your saved data, preferences, and profile information will be permanently erased. This cannot be undone."
        case .premiumAutoRenewing:
            return "Deleting your account will permanently erase your data, but it will not cancel your Meigan Premium subscription. You will continue to be billed by Apple unless you cancel."
        case .premiumExpiring:
            return "Your Premium subscription is already set to expire, but deleting your account now will forfeit your remaining Premium access. Your data will be permanently erased."
        }
    }

    private var showsManageButton: Bool {
        state == .premiumAutoRenewing
    }

    var body: some View {
        DialogScrim(onTapOutside: onCancel) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.red)
                Text("Delete Account?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
            }

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                if showsManageButton {
                    Button(action: onManage) {
                        Text("Manage Subscriptions")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive, action: onDelete) {
                    Text("Delete Account")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Shared chrome

/// Dimmed full-screen scrim with a centered rounded card. Tapping outside the
/// card invokes `onTapOutside`.
private struct DialogScrim<Content: View>: View {
    let onTapOutside: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onTapOutside)

            VStack(spacing: 20) {
                content()
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 32)
        }
    }
}
