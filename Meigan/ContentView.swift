//
//  ContentView.swift
//  Meigan
//
//  Root: onboarding → login → main app.
//

import SwiftUI
import Supabase

struct ContentView: View {
    /// Set to `false` before shipping so onboarding only runs once (uses `hasCompletedOnboarding`).
    private let alwaysShowOnboardingAtLaunch = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// When `alwaysShowOnboardingAtLaunch` is true, resets each cold launch so onboarding shows every time.
    @State private var onboardingDismissedThisSession = false

    @EnvironmentObject private var appSession: AppSession

    @EnvironmentObject private var subscriptions: SubscriptionManager

    private var showOnboarding: Bool {
        if alwaysShowOnboardingAtLaunch {
            return !onboardingDismissedThisSession
        }
        return !hasCompletedOnboarding
    }

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView {
                    onboardingDismissedThisSession = true
                    if !alwaysShowOnboardingAtLaunch {
                        hasCompletedOnboarding = true
                    }
                }
            } else if !appSession.shouldShowMainApp {
                NavigationStack {
                    LoginView()
                }
            } else if subscriptions.shouldPresentPaywall {
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
                        subscriptions.skipPaywall()
                    },
                    onSelectPro: {
                        Task { await subscriptions.upgradeToPro() }
                    }
                )
                .task { await subscriptions.loadProductsIfNeeded() }
            } else {
                NavigationStack {
                    HomeView()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSession())
        .environmentObject(SettingsManager())
        .environmentObject(SubscriptionManager())
}
