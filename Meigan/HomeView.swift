//
//  HomeView.swift
//  Meigan
//
//  Created by Ryan Chen on 2026-02-19.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager

    @State private var showARMeasurement = false
    @State private var showAccount = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            let logoSize = geometry.size.height / 4

            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(spacing: 32) {
                        VStack(spacing: 12) {
                            Image("Logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: logoSize, height: logoSize)

                            Text("Meigan")
                                .font(.largeTitle)
                                .fontWeight(.bold)

                            Text("Precision 3D measurement")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Button {
                            showARMeasurement = true
                        } label: {
                            Text("Start Measuring")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 24)

                        Button {
                            // TODO: Show how it works
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.circle")
                                Text("How it works")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)

                ProfileAvatarMenu(
                    initial: profileInitial,
                    onAccount: { showAccount = true },
                    onSettings: { showSettings = true },
                    onLogOut: { appSession.logOut() }
                )
                .padding(.leading, 20)
                .padding(.top, 12)
            }
        }
        .navigationDestination(isPresented: $showARMeasurement) {
            ARMeasurementView()
        }
        .navigationDestination(isPresented: $showAccount) {
            AccountView()
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var profileInitial: String {
        let first = settings.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let char = first.first {
            return String(char).uppercased()
        }
        return appSession.isGuest ? "G" : "?"
    }
}

// MARK: - Profile Avatar + Dropdown Menu

private struct ProfileAvatarMenu: View {
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
            AvatarBadge(initial: initial)
        }
    }
}

private struct AvatarBadge: View {
    let initial: String

    var body: some View {
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

// MARK: - Account Screen

struct AccountView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var subscriptions: SubscriptionManager

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
    }

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
                    // TODO: Connect subscription update flow.
                }
                planActionButton(
                    title: "Cancel subscription",
                    systemImage: "xmark.circle"
                ) {
                    // TODO: Connect cancel subscription flow.
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
                // TODO: Navigate to personal info editor.
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
                // TODO: Navigate to password change flow.
            }
            Divider().padding(.leading, 56)
            AccountRow(
                title: "Delete account",
                systemImage: "trash",
                isDestructive: true
            ) {
                // TODO: Navigate to account deletion confirmation.
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

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
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
    .environmentObject(SubscriptionManager())
}
