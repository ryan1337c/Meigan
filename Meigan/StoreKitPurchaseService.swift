import StoreKit
import Foundation
import Combine

enum StoreKitPurchaseError: LocalizedError {
    case productNotFound
    case unverifiedTransaction
    case appleIDAlreadyLinked

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Pro plan is unavailable right now. Please try again later."
        case .unverifiedTransaction:
            return "Purchase could not be verified. Please contact support."
        case .appleIDAlreadyLinked:
            return "This Apple ID is already linked to another account."
        }
    }
}
@MainActor
protocol SubscriptionPurchasing: AnyObject {
    var proProduct: Product? { get }
    var proPriceLabel: String? { get }

    func loadProducts() async 
    func purchasePro() async throws -> VerificationResult<Transaction>?
    func restorePurchases() async throws -> Bool
    func hasActiveProEntitlement() async throws -> Bool
    func currentProExpirationDate() async -> Date?
    func currentProAutoRenewStatus() async -> Bool?
    func startTransactionListener()
    func currentProEntitlement() async -> VerificationResult<Transaction>?
}

@MainActor 
final class StoreKitPurchaseService: SubscriptionPurchasing, ObservableObject {

    @Published private(set) var proProduct: Product?

    var proPriceLabel: String? {
        guard let proProduct else { return nil }
        return "\(proProduct.displayPrice) / month"
    }

    // Thin "poke" fired when Transaction.updates delivers a Pro transaction
    // (renewal, refund, external purchase). The listener doesn't interpret the
    // event — SubscriptionManager re-derives state via reconcileEntitlements().
    var onEntitlementChanged: ((VerificationResult<Transaction>) async -> Void)?

    // Listens for StoreKit transactions and updates the entitlement
    // Accounts for for purchases made outside the app
    private var transactionListenerTask: Task<Void, Never>?

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Products

    func loadProducts() async {
        do {
            let products = try await Product.products(for: MeiganProducts.all)
            proProduct = products.first { $0.id == MeiganProducts.proMonthly }

            print("StoreKit loaded:", products.map(\.id))
            print("Matched proProduct:", proProduct?.id ?? "nil")

        } catch {
            print("Failed to load products: \(error)")
            proProduct = nil
        }
    }

    // MARK: - Purchase

    func purchasePro() async throws -> VerificationResult<Transaction>? {    
        if proProduct == nil {
            await loadProducts()
        }

        guard let product = proProduct else {
            throw StoreKitPurchaseError.productNotFound
        }

        let result = try await product.purchase()

        switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)

                 print("Purchase expiration:", transaction.expirationDate as Any)
                 
                // Strict validation: 409 / overlap errors surface to the paywall.
                // On failure the transaction stays unfinished so StoreKit retries.
                try await SubscriptionValidationService.validateOnServer(transaction: verification)
                await transaction.finish()
                return verification

            case .userCancelled, .pending:
                return nil
            
            @unknown default:
                return nil
        }
    }

    // MARK: - Restore
    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()

        guard let result = await currentProEntitlement() else { return false }

        // Keep strict validation so 409 / overlap still surfaces on Restore tap
        try await SubscriptionValidationService.validateOnServer(transaction: result)
        return true


    }

    // MARK: - Entitlements
    func hasActiveProEntitlement() async throws -> Bool {
        // Apple id bounded entitlement 
        let tier = try await SubscriptionValidationService.syncTierFromServer()
        return tier == .pro
    }

    func currentProEntitlement() async -> VerificationResult<Transaction>? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == MeiganProducts.proMonthly else { continue }
            guard isProEntitlementActive(transaction) else { continue }
            
            return result
        }
        return nil
    }

    /// Renewal/expiration date of the active Pro entitlement, if any.
    /// `nil` when there is no active Pro subscription (or it never expires).
    func currentProExpirationDate() async -> Date? {
        guard let result = await currentProEntitlement(),
            case .verified(let transaction) = result else { return nil }
        return transaction.expirationDate
    }

    /// Auto-renewal preference for the active Pro subscription.
    /// - Returns: `true` if the subscription will auto-renew, `false` if the
    ///   user has already turned auto-renew off (still active until expiry),
    ///   or `nil` when there is no active Pro entitlement / status is unknown.
    func currentProAutoRenewStatus() async -> Bool? {
        guard await currentProEntitlement() != nil else { return nil }

        if proProduct == nil {
            await loadProducts()
        }
        guard let subscription = proProduct?.subscription else { return nil }

        let statuses = (try? await subscription.status) ?? []
        for status in statuses {
            guard case .verified(let renewalInfo) = status.renewalInfo else { continue }
            if renewalInfo.currentProductID == MeiganProducts.proMonthly {
                return renewalInfo.willAutoRenew
            }
        }
        return nil
    }

    // MARK: - Transaction listener (start once at launch)

    func startTransactionListener() {
        guard transactionListenerTask == nil else { return }

        transactionListenerTask = Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == MeiganProducts.proMonthly else { continue }

                // Notify only — reconcileEntitlements() re-scans StoreKit and
                // handles server validation/sync for this update.
                await onEntitlementChanged?(result)
                await transaction.finish()
            }
        }
    }

    // MARK: - Private

    private func isProEntitlementActive(_ transaction: Transaction) -> Bool {
        transaction.revocationDate == nil &&
        (transaction.expirationDate.map { $0 > Date() } ?? true)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
            case .unverified:
                throw StoreKitPurchaseError.unverifiedTransaction
            case .verified(let transaction):
                // Sends back either of the 3 cases: 
                // 1. User buys subscription 2. Check auto-renew status 3. Verifying app download
                return transaction 
        }
    }
}
