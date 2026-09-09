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
                    isGuest: appSession.isGuest,
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

/// Avatar button that opens Account / Settings / Log Out (or Sign In for guests).
/// Shared by `HomeView` and the AR footer.
struct ProfileAvatarMenu: View {
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
            AvatarBadge(initial: initial)
        }
    }
}

struct AvatarBadge: View {
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

#Preview {
    NavigationStack {
        HomeView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
    .environmentObject(SubscriptionManager())
}
