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
    weak var settingsManager: SettingsManager? {
        didSet { flushPendingSyncIfNeeded() }
    }
    weak var subscriptionManager: SubscriptionManager? {
        didSet { flushPendingSyncIfNeeded() }
    }

    /// Set when an authenticated event arrives before the managers are injected
    /// (the listener starts in `init`, the managers attach later in `MeiganApp`).
    /// Lets the cloud sync run once they become available.
    private var pendingAuthenticatedSync = false
    /// Guards against re-fetching cloud state on every periodic `.tokenRefreshed`,
    /// which would otherwise overwrite in-progress local edits.
    private var hasSyncedThisLaunch = false

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
            for await (event, session) in supabase.auth.authStateChanges {
                switch event {
                case .signedIn:
                    await activateAuthenticatedSession()
                case .initialSession:
                    // Emitted once per launch with the locally stored session.
                    if session == nil {
                        isAuthenticated = false
                    } else if session?.isExpired == false {
                        await activateAuthenticatedSession()
                    }
                    // Expired stored session: keep the current state. The SDK
                    // refreshes it in the background and emits `.tokenRefreshed`
                    // (or `.signedOut`) next, where the sync runs.
                case .tokenRefreshed:
                    isAuthenticated = true
                    // Only sync if we haven't already this launch — covers the
                    // expired-initial-session case without re-fetching (and
                    // clobbering local edits) on routine periodic refreshes.
                    if !hasSyncedThisLaunch {
                        await syncManagers()
                    }
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

    private func activateAuthenticatedSession() async {
        isAuthenticated = true
        isGuest = false
        UserDefaults.standard.set(false, forKey: Self.guestKey)
        await syncManagers()
    }

    /// Pulls settings/subscription from the cloud. If the managers aren't
    /// injected yet, defers until they are (see `flushPendingSyncIfNeeded`).
    private func syncManagers() async {
        guard let settingsManager, let subscriptionManager else {
            pendingAuthenticatedSync = true
            return
        }
        pendingAuthenticatedSync = false
        hasSyncedThisLaunch = true
        await settingsManager.syncFromCloud()
        await subscriptionManager.handleSignIn()
    }

    private func flushPendingSyncIfNeeded() {
        guard pendingAuthenticatedSync,
              settingsManager != nil,
              subscriptionManager != nil else { return }
        Task { await syncManagers() }
    }
}
