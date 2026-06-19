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

enum SignInSubscriptionOutcome: Equatable {
    case existingUser(tier: SubscriptionTier)
    case newUser(tier: SubscriptionTier)
    case fetchFailedUsedCache
}

enum SubscriptionPaywallPolicy {
    static func shouldPresent(outcome: SignInSubscriptionOutcome) -> Bool {
        switch outcome {
        case .newUser(let tier):
            return tier != .pro
        case .existingUser, .fetchFailedUsedCache:
            return false
        }
    }
}

enum SubscriptionTier: String, Codable {
    case free = "free"
    case pro  = "pro"
}

@MainActor
final class SubscriptionManager: ObservableObject {

    private static let tierKey = "meigan.subscriptionTier"
    private let defaults = UserDefaults.standard

    @Published private(set) var currentTier: SubscriptionTier = .free

    @Published private(set) var shouldPresentPaywall: Bool = false
    
    // Orchestration surface for SubscriptionPaywallView
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var purchaseError: String?
    @Published private(set) var proPriceLabel: String?

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

        let outcome = await resolveSignInOutcome(userId: userId)

        shouldPresentPaywall = SubscriptionPaywallPolicy.shouldPresent(outcome: outcome)

        await reconcileWithStoreKit()
    }

    /// Called by AppSession on `.signedOut` or guest mode.
    func handleSignOut() {
        setTierLocally(.free)
        shouldPresentPaywall = false
        purchaseError = nil
        isPurchasing = false
    }

    // MARK: - Upgrade / Downgrade

    private var purchaseService: StoreKitPurchaseService?

    func attach(purchaseService: StoreKitPurchaseService) {
        self.purchaseService = purchaseService
    }

    func upgradeToPro() async {
        purchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }

        guard let purchaseService else { return }

        do {
            let purchased = try await purchaseService.purchasePro()
            if purchased {
                shouldPresentPaywall = false
            }
        }
        catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Call when the user upgrades or changes their tier.
    /// Updates locally immediately and pushes to Supabase.
    func updateTier(to tier: SubscriptionTier) {
        guard tier != currentTier else { return }
        setTierLocally(tier)
        pushTierToCloud(tier)
    }

    func loadProductsIfNeeded() async {
        guard proPriceLabel == nil else { return }
        await purchaseService?.loadProducts()
        proPriceLabel = purchaseService?.proPriceLabel

        print("proPriceLabel:", proPriceLabel ?? "nil")
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

    func skipPaywall() {
        shouldPresentPaywall = false
    }

    // Returns the subscription tier for the user, or nil if no subscription exists.
    private func resolveSignInOutcome(userId: UUID) async -> SignInSubscriptionOutcome {
        do {
            let row: SubscriptionRow = try await supabase
                .from("subscriptions")
                .select()
                .eq("uid", value: userId.uuidString)
                .single()
                .execute()
                .value
        
            setTierLocally(row.tier)
            print("Same user, same tier:", row.tier)
            return .existingUser(tier: row.tier)
        } catch where isNoRowsError(error) {
            await createFreeSubscription(userId: userId)
            setTierLocally(.free)
            print("New user, tier: free")
            return .newUser(tier: .free)
        }
        catch {
            print("Subscription fetch failed, using local cache: \(error)")
            // current tier staus whatever UserDefaults has
            return .fetchFailedUsedCache
        }
    }

    // Helper to check if a Supabase error is due to no rows found.
    private func isNoRowsError(_ error: Error) -> Bool {
        if let postgrest = error as? PostgrestError {
            return postgrest.code == "PGRST116"
        }
        // Fallback: some SDK versions wrap the error
        let message = String(describing: error)
        return message.contains("PGRST116") || message.contains("0 rows")
    }

    private func reconcileWithStoreKit() async {
        guard let purchaseService else { return }

        do {
            let hasEntitlement = try await purchaseService.hasActiveProEntitlement()
            if hasEntitlement && currentTier == .free {
                updateTier(to: .pro) // Apple says pro, Supabase stale
            } else if !hasEntitlement && currentTier == .pro {
                updateTier(to: .free) // Subscription expired / refunded
            }
        }
        catch {
            print("StoreKit entitlement check failed: \(error)")
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
}