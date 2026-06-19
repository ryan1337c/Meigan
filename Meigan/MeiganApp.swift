//
//  MeiganApp.swift
//  Meigan
//
//  Created by Ryan Chen on 2026-02-19.
//

import SwiftUI

@main
struct MeiganApp: App {
    @StateObject private var appSession = AppSession()
    @StateObject private var settings = SettingsManager()
    @StateObject private var subscriptions = SubscriptionManager()
    @StateObject private var purchaseService = StoreKitPurchaseService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appSession)
                .environmentObject(settings)
                .environmentObject(subscriptions)
                .onAppear {
                    // Attach StoreKit to subscription orchestration
                    subscriptions.attach(purchaseService: purchaseService)

                    // Live entitlement updates -> sync tier + Supabase
                    purchaseService.onEntitlementChanged = { [weak subscriptions] isPro in
                        subscriptions?.updateTier(to: isPro ? .pro : .free)
                    }

                    // Existing auth wiring
                    appSession.settingsManager = settings
                    appSession.subscriptionManager = subscriptions

                    // Wire current user ID provider to StoreKitPurchaseService
                    purchaseService.currentUserIdProvider = { 
                        appSession.supabase.auth.currentSession?.user.id 
                    }

                    // Start listening for renewals / refunds / external purchases
                    purchaseService.startTransactionListener()

                    // Preload product for paywall price
                    Task {
                        await subscriptions.loadProductsIfNeeded()
                    }

                }
        }
    }
}
