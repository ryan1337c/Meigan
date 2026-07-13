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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appSession)
                .environmentObject(settings)
                .environmentObject(subscriptions)
                .onAppear {
                    // Attach StoreKit to subscription orchestration
                    // (also wires Transaction.updates -> reconcileEntitlements)
                    subscriptions.attach(purchaseService: purchaseService)

                    // Existing auth wiring
                    appSession.settingsManager = settings
                    appSession.subscriptionManager = subscriptions

                    // Start listening for renewals / refunds / external purchases
                    purchaseService.startTransactionListener()

                    // Preload product for paywall price
                    Task {
                        await subscriptions.loadProductsIfNeeded()
                    }

                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    Task {
                        await subscriptions.reconcileEntitlements()
                    }
                }
        }
    }
}
