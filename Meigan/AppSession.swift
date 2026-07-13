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

    /// True while the user is in the "forgot password" flow. The email recovery
    /// step establishes a real Supabase session (the SDK emits `.signedIn`), but
    /// we don't want that to drop the user into the main app — they should stay
    /// in the reset flow and return to the login screen afterwards. While this is
    /// set, auth state transitions are ignored.
    @Published var isResettingPassword = false

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

    var shouldShowMainApp: Bool { (isAuthenticated || isGuest) && !isResettingPassword }

    init() {
        isGuest = UserDefaults.standard.bool(forKey: Self.guestKey)
        isAuthenticated = false
        listenForAuthChanges()
    }

    func continueAsGuest() {
        isGuest = true
        UserDefaults.standard.set(true, forKey: Self.guestKey)
        settingsManager?.markSignedOut()
        subscriptionManager?.handleSignOut()
    }

    /// Call when entering the "forgot password" flow so the recovery session that
    /// the email-verification step creates doesn't auto-navigate into the app.
    func beginPasswordReset() {
        isResettingPassword = true
    }

    /// Call when leaving the "forgot password" flow (success or cancel). Tears down
    /// any recovery session so the user lands back on a clean login screen and signs
    /// in with their new password.
    func endPasswordReset() {
        isResettingPassword = false
        Task { try? await supabase.auth.signOut() }
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

    func deleteAccount() async throws{
        try await supabase.functions.invoke("delete-account");
        logOut()
    }

    // MARK: - Private

    private func listenForAuthChanges() {
        Task {
            for await (event, session) in supabase.auth.authStateChanges {
                // While resetting a password, the email recovery step signs the
                // user in behind the scenes. Ignore every transition so we stay in
                // the reset flow; `endPasswordReset()` performs an explicit sign-out.
                if isResettingPassword { continue }
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
                    // Only sync if we haven't already this launch — covers the
                    // expired-initial-session case without re-fetching (and
                    // clobbering local edits) on routine periodic refreshes.
                    if !hasSyncedThisLaunch {
                        isGuest = false
                        let synced = await syncManagers()
                        if synced {
                            isAuthenticated = true
                        }
                    }
                    else {
                        isAuthenticated = true
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
        isGuest = false
        UserDefaults.standard.set(false, forKey: Self.guestKey)
        let synced = await syncManagers()
        if synced {
            isAuthenticated = true
        }
    }

    /// Pulls settings/subscription from the cloud. If the managers aren't
    /// injected yet, defers until they are (see `flushPendingSyncIfNeeded`).
    @discardableResult
    private func syncManagers() async -> Bool {
        guard let settingsManager, let subscriptionManager else {
            pendingAuthenticatedSync = true
            return false
        }
        pendingAuthenticatedSync = false
        hasSyncedThisLaunch = true
        await settingsManager.syncFromCloud()
        await subscriptionManager.handleSignIn()
        return true
    }

    private func flushPendingSyncIfNeeded() {
        guard pendingAuthenticatedSync,
              settingsManager != nil,
              subscriptionManager != nil else { return }
        Task { 
            let synced = await syncManagers() 
            if synced {
                isAuthenticated = true
            }
        }
    }
}
