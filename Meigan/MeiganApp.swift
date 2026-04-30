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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appSession)
                .environmentObject(settings)
                .environmentObject(subscriptions)
                .onAppear {
                    appSession.settingsManager = settings
                    appSession.subscriptionManager = subscriptions
                }
        }
    }
}
