//
//  AppSession.swift
//  Meigan
//
//  Drives root navigation. Listens to Supabase auth state changes
//  and delegates to domain-specific managers on auth events.
//

import Combine
import Foundation
import SwiftUI
import Supabase

@MainActor
final class AppSession: ObservableObject {
    private static let guestKey = "meigan.isGuest"

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isGuest = false

    /// Injected by MeiganApp so auth events can trigger domain-specific sync.
    weak var settingsManager: SettingsManager?
    weak var subscriptionManager: SubscriptionManager?

    var shouldShowMainApp: Bool { isAuthenticated || isGuest }

    init() {
        isGuest = UserDefaults.standard.bool(forKey: Self.guestKey)
        isAuthenticated = supabase.auth.currentSession != nil
        listenForAuthChanges()
    }

    func continueAsGuest() {
        isGuest = true
        UserDefaults.standard.set(true, forKey: Self.guestKey)
        settingsManager?.markSignedOut()
        subscriptionManager?.handleSignOut()
    }

    func logOut() {
        isGuest = false
        UserDefaults.standard.set(false, forKey: Self.guestKey)
        settingsManager?.markSignedOut()
        subscriptionManager?.handleSignOut()
        Task {
            try? await supabase.auth.signOut()
        }
    }

    // MARK: - Private

    private func listenForAuthChanges() {
        Task {
            for await (event, _) in supabase.auth.authStateChanges {
                switch event {
                case .signedIn:
                    isAuthenticated = true
                    isGuest = false
                    UserDefaults.standard.set(false, forKey: Self.guestKey)
                    await settingsManager?.syncFromCloud()
                    await subscriptionManager?.handleSignIn()
                case .signedOut:
                    isAuthenticated = false
                    settingsManager?.markSignedOut()
                    subscriptionManager?.handleSignOut()
                default:
                    break
                }
            }
        }
    }
}
