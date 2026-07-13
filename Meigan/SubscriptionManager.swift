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
import StoreKit

enum SubscriptionTier: String, Codable {
    case free = "free"
    case pro  = "pro"
}

/// Subscription context used to tailor the account-deletion confirmation copy.
enum AccountDeletionSubscriptionState: Equatable {
    /// Free user with no active subscription.
    case free
    /// Active Pro subscription that is still set to auto-renew.
    case premiumAutoRenewing
    /// Active Pro subscription with auto-renew already turned off (expiring).
    case premiumExpiring
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

    /// Renewal/expiration date for the active Pro subscription, used by the
    /// cancel-subscription dialog. `nil` until refreshed (or when on Free).
    @Published private(set) var proExpirationDate: Date?

    // StoreKitPurchaseService is injected by MeiganApp
    private var purchaseService: StoreKitPurchaseService?

    // Expiry timer
    private var expiryTimerTask: Task<Void, Never>?

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

        let isNewUser = await subscriptionRowExists(userId: userId)

        await reconcileEntitlements()

        shouldPresentPaywall = isNewUser && currentTier != .pro
    }

    /// Called by AppSession on `.signedOut` or guest mode.
    func handleSignOut() {
        setTierLocally(.free)
        shouldPresentPaywall = false
        purchaseError = nil
        isPurchasing = false
        expiryTimerTask?.cancel()
        expiryTimerTask = nil
    }

    @Published private(set) var isRestoring: Bool = false
    @Published private(set) var restoreMessager: String?

    func restorePurchases() async {
        purchaseError = nil
        restoreMessager = nil
        isRestoring = true
        defer { isRestoring = false }

        guard let purchaseService else { return }

        do {
            let restored = try await purchaseService.restorePurchases()
            await reconcileEntitlements()

            if restored {
                restoreMessager = "Your Pro subscription has been restored."
                shouldPresentPaywall = false
            } else {
                restoreMessager = "No active Pro subscription found."
            }
        }
        catch {
            purchaseError = error.localizedDescription
        }
    }

    /// Clears the restore result message once its confirmation UI is dismissed.
    func clearRestoreMessage() {
        restoreMessager = nil
    }

    // MARK: - Updating Tier

    func attach(purchaseService: StoreKitPurchaseService) {
        self.purchaseService = purchaseService

        // Transaction.updates (renewal, refund, external purchase) -> re-check
        // everything through the single reconcile path.
        purchaseService.onEntitlementChanged = { [weak self] transaction in
            await self?.reconcileEntitlements(using: transaction)
        }
    }

    func upgradeToPro() async {
        purchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }

        guard let purchaseService else { return }

        do {
            let purchased = try await purchaseService.purchasePro()
            if purchased {
                await reconcileEntitlements()
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

    /// Refreshes the Pro renewal/expiration date from StoreKit.
    func refreshProExpirationDate() async {
        proExpirationDate = await purchaseService?.currentProExpirationDate()
    }

    /// Resolves which account-deletion warning to show, based on the user's
    /// current subscription and StoreKit auto-renewal status.
    func accountDeletionState() async -> AccountDeletionSubscriptionState {
        guard currentTier == .pro, let purchaseService else { return .free }

        switch await purchaseService.currentProAutoRenewStatus() {
        case .some(true):
            return .premiumAutoRenewing
        case .some(false):
            return .premiumExpiring
        case .none:
            // Cached Pro but no active StoreKit entitlement: no billing concern,
            // fall back to the standard data-deletion warning.
            return .free
        }
    }

    func loadProductsIfNeeded() async {
        guard proPriceLabel == nil else { return }
        await purchaseService?.loadProducts()
        proPriceLabel = purchaseService?.proPriceLabel

        print("proPriceLabel:", proPriceLabel ?? "nil")
    }

    func setTierLocally(_ tier: SubscriptionTier) {
        currentTier = tier
        defaults.set(tier.rawValue, forKey: Self.tierKey)
    }

    func fetchProfile() async throws -> Profile {
        guard let userId = supabase.auth.currentSession?.user.id else {
            return Profile(firstName: "", lastName: "")
        }

        let row: Profile = try await supabase
            .from("profile")
            .select("first_name, last_name")
            .eq("uid", value: userId)
            .single()
            .execute()
            .value

        return row
    }

    func updateProfile(firstName: String, lastName: String) async throws {
        guard let userId = supabase.auth.currentSession?.user.id else { return }

        struct ProfileUpsert: Encodable {
            let uid: UUID
            let firstName: String
            let lastName: String

            enum CodingKeys: String, CodingKey {
                case uid
                case firstName = "first_name"
                case lastName = "last_name"
            }
        }

        try await supabase
            .from("profile")
            .upsert(
                ProfileUpsert(
                    uid: userId,
                    firstName: firstName,
                    lastName: lastName
                ),
                onConflict: "uid"
            )
            .execute()
    }

    // MARK - Entitlement Reconciliation

    // Single point of truth for entitlement status
    // Scans StoreKit, validate/sync with server, apply local tier
    // Called on app launch, and later expiry timer
    func reconcileEntitlements(
        using deliveredTransaction: VerificationResult<StoreKit.Transaction>? = nil
    ) async {
        guard supabase.auth.currentSession != nil,
            let purchaseService else { return }

        let transaction: VerificationResult<StoreKit.Transaction>?

        if let deliveredTransaction {
            transaction = deliveredTransaction
        } else {
            transaction = await purchaseService.currentProEntitlement()
        }

        do {
            if let transaction {
                try await SubscriptionValidationService.validateOnServer(
                    transaction: transaction
                )
            }

            let tier = try await SubscriptionValidationService.syncTierFromServer()
            setTierLocally(tier)
        } catch {
            // Preserve the last known entitlement during transient failures.
            print("Entitlement reconciliation failed:", error)
        }

        await refreshProExpirationDate()
        scheduleExpiryCheck()
    }

    private func scheduleExpiryCheck() {
        expiryTimerTask?.cancel()
        expiryTimerTask = nil

        guard currentTier == .pro,
              let expiration = proExpirationDate else { return }
        
        let fireDate = expiration.addingTimeInterval(30) // 30second buffer after expiration to prevent race conditions
        let delay = fireDate.timeIntervalSinceNow
        guard delay > 0 else { 
            // Already past expiry - reconcile immediately 
            Task { await reconcileEntitlements() }
            return
        }

        expiryTimerTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await reconcileEntitlements()
        }
    }

    // MARK: - Private

    private func pushTierToCloud(_ tier: SubscriptionTier) {
        guard let userId = supabase.auth.currentSession?.user.id else { return }

        struct SubscriptionUpsert: Encodable {
            let uid: UUID
            let tier: String
        }
        
        Task {
            do {
                try await supabase
                    .from("subscriptions")
                    .upsert(
                        SubscriptionUpsert(uid: userId, tier: tier.rawValue),
                        onConflict: "uid"
                    )
                    .execute()
            } catch {
                print("Failed to push tier to cloud: \(error)")
            }
        }
    }

    /// Inserts a "free" subscription row for a newly registered user.
    // Deprecated, or used for offline mode
    private func createFreeSubscription(userId: UUID) async {

        struct Subscription: Encodable {
            let uid: UUID
            let tier: String
        }

        do {
            try await supabase
                .from("subscriptions")
                .upsert(
                    Subscription(uid: userId, tier: SubscriptionTier.free.rawValue),
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
    private func subscriptionRowExists(userId: UUID) async -> Bool {
        do {
            _ = try await supabase
                .from("subscriptions")
                .select("uid")          // minimal column
                .eq("uid", value: userId)
                .single()
                .execute()
            return false   // row exists → existing user
        } catch where isNoRowsError(error) {
            print("No row found, new user")
            return true    // no row → new user
        } catch {
            print("Subscription fetch failed, using local cache")
            return false   // fetch failed → treat as existing (no paywall); reconcile uses cache/StoreKit
        }
    }
    // private func resolveSignInOutcome(userId: UUID) async -> SignInSubscriptionOutcome {
    //     do {
    //         let row: SubscriptionRow = try await supabase
    //             .from("subscriptions")
    //             .select()
    //             .eq("uid", value: userId)
    //             .single()
    //             .execute()
    //             .value
        
    //         setTierLocally(row.tier)
    //         print("Same user, same tier:", row.tier)
    //         return .existingUser(tier: row.tier)
    //     } catch where isNoRowsError(error) {
    //         // await createFreeSubscription()
    //         let tier = (try? await SubscriptionValidationService.syncTierFromServer()) ?? .free
    //         setTierLocally(tier)
    //         return .newUser(tier: tier)
    //     }
    //     catch {
    //         print("Subscription fetch failed, using local cache: \(error)")
    //         // current tier staus whatever UserDefaults has
    //         return .fetchFailedUsedCache
    //     }
    // }

    // Helper to check if a Supabase error is due to no rows found.
    private func isNoRowsError(_ error: Error) -> Bool {
        if let postgrest = error as? PostgrestError {
            return postgrest.code == "PGRST116"
        }
        // Fallback: some SDK versions wrap the error
        let message = String(describing: error)
        return message.contains("PGRST116") || message.contains("0 rows")
    }

    // Deprecated, or used for offline mode
    private func syncEntitlementWithStoreKit() async {
        // guard let userId = supabase.auth.currentSession?.user.id else { return }
        // guard let purchaseService else { return }

        // do {
        //     let hasEntitlement = try await purchaseService.hasActiveProEntitlement(for: userId)
        //     let targetTier: SubscriptionTier = hasEntitlement ? .pro : .free

        //     if targetTier != currentTier {
        //         updateTier(to: targetTier)
        //     }
        // }
        // catch {
        //     print("StoreKit entitlement check failed: \(error)")
        // }
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

// MARK: - Profile Model
struct Profile: Equatable, Decodable {
    let firstName: String
    let lastName: String

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

}