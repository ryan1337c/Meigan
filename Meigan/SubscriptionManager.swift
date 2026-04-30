//
//  SubscriptionManager.swift
//  Meigan
//
//  Owns all subscription-related state and Supabase sync.
//  AppSession notifies this manager on auth events; views
//  observe @Published properties for tier-gated UI.
//

import Combine
import Foundation
import SwiftUI
import Supabase

enum SubscriptionTier: String, Codable {
    case free = "free"
    case pro  = "pro"
}

@MainActor
final class SubscriptionManager: ObservableObject {

    private static let tierKey = "meigan.subscriptionTier"
    private let defaults = UserDefaults.standard

    @Published private(set) var currentTier: SubscriptionTier = .free

    var isPro: Bool { currentTier == .pro }

    // MARK: - Init

    init() {
        if let stored = defaults.string(forKey: Self.tierKey),
           let tier = SubscriptionTier(rawValue: stored) {
            currentTier = tier
        }
    }

    // MARK: - Auth Lifecycle

    /// Called by AppSession on `.signedIn`. Fetches the user's subscription
    /// from Supabase; if none exists (new account), creates a "free" row.
    /// Falls back to locally cached tier if fetch fails.
    func handleSignIn() async {
        guard let userId = supabase.auth.currentSession?.user.id else { return }
        
        do {
            let row: SubscriptionRow = try await supabase
                .from("subscriptions")
                .select()
                .eq("uid", value: userId.uuidString)
                .single()
                .execute()
                .value
        
            setTierLocally(row.tier)
        } catch {
            print("Subscription fetch failed, using local cache: \(error)")
            await createFreeSubscription(userId: userId)
            setTierLocally(.free)
        }
    }

    /// Called by AppSession on `.signedOut` or guest mode.
    func handleSignOut() {
        setTierLocally(.free)
    }

    // MARK: - Upgrade / Downgrade

    /// Call when the user upgrades or changes their tier.
    /// Updates locally immediately and pushes to Supabase.
    func upgradeTier(to tier: SubscriptionTier) {
        guard tier != currentTier else { return }
        setTierLocally(tier)
        pushTierToCloud(tier)
    }

    // MARK: - Private

    private func setTierLocally(_ tier: SubscriptionTier) {
        currentTier = tier
        defaults.set(tier.rawValue, forKey: Self.tierKey)
    }

    private func pushTierToCloud(_ tier: SubscriptionTier) {
        guard let userId = supabase.auth.currentSession?.user.id else { return }
        
        Task {
            do {
                try await supabase
                    .from("subscriptions")
                    .upsert(
                        [
                            "uid": userId.uuidString,
                            "tier": tier.rawValue
                        ],
                        onConflict: "uid"
                    )
                    .execute()
            } catch {
                print("Failed to push tier to cloud: \(error)")
            }
        }
    }

    /// Inserts a "free" subscription row for a newly registered user.
    private func createFreeSubscription(userId: UUID) async {
        do {
            try await supabase
                .from("subscriptions")
                .upsert(
                    [
                        "uid": userId.uuidString,
                        "tier": SubscriptionTier.free.rawValue
                    ],
                    onConflict: "uid"
                )
                .execute()
        } catch {
            print("Failed to create free subscription: \(error)")
        }
    }
}

// MARK: - Supabase Row Model

struct SubscriptionRow: Decodable {
    let userId: UUID
    let tier: SubscriptionTier

    enum CodingKeys: String, CodingKey {
        case userId = "uid"
        case tier
    }
}
