import StoreKit
import Foundation
import Combine

enum StoreKitPurchaseError: LocalizedError {
    case productNotFound
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Pro plan is unavailable right now. Please try again later."
        case .unverifiedTransaction:
            return "Purchase could not be verified. Please contact support."
        }
    }
}
@MainActor
protocol SubscriptionPurchasing: AnyObject {
    var proProduct: Product? { get }
    var proPriceLabel: String? { get }

    func loadProducts() async 
    func purchasePro() async throws -> Bool
    func restorePurchases() async throws -> Bool
    func hasActiveProEntitlement() async throws -> Bool
    func currentProExpirationDate() async -> Date?
    func startTransactionListener()
}

@MainActor 
final class StoreKitPurchaseService: SubscriptionPurchasing, ObservableObject {

    @Published private(set) var proProduct: Product?

    var proPriceLabel: String? {
        guard let proProduct else { return nil }
        return "\(proProduct.displayPrice) / month"
    }

    // Called when StoreKit entitlement changes (renewal, cancel, restore)
    var onEntitlementChanged: ((Bool) -> Void)?

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

    func purchasePro() async throws -> Bool {
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
                try await SubscriptionValidationService.validateOnServer(transaction: verification)
                await handleVerifiedTransaction(transaction)
                await transaction.finish()
                return true

            case .userCancelled, .pending:
                return false
            
            @unknown default:
                return false
        }
    }

    // MARK: - Restore
    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()

        // For now, we check apple id for entitlements
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.productID == MeiganProducts.proMonthly else { continue }

            let active = transaction.expirationDate.map { $0 > Date() } ?? true
            guard active else { continue }

            try await SubscriptionValidationService.validateOnServer(transaction: result)

        }
        let tier = try await SubscriptionValidationService.syncTierFromServer()
        return tier == .pro
    }

    // MARK: - Entitlements
    func hasActiveProEntitlement() async throws -> Bool {
        let tier = try await SubscriptionValidationService.syncTierFromServer()
        return tier == .pro
    }

    /// Renewal/expiration date of the active Pro entitlement, if any.
    /// `nil` when there is no active Pro subscription (or it never expires).
    func currentProExpirationDate() async -> Date? {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.productID == MeiganProducts.proMonthly else { continue }

            if let expiration = transaction.expirationDate, expiration > Date() {
                return expiration
            }
        }
        return nil
    }

    // MARK: - Transaction listener (start once at launch)

    func startTransactionListener() {
        guard transactionListenerTask == nil else { return }

        transactionListenerTask = Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break}
                guard let transaction = try? checkVerified(result) else { continue }

                await handleVerifiedTransaction(transaction)
                await transaction.finish()
            }
        }
    }

    // MARK: - Private
    private func handleVerifiedTransaction(_ transaction: Transaction) async {
        guard transaction.productID == MeiganProducts.proMonthly else { return }

        let isActive: Bool
        if let expiration = transaction.expirationDate {
            isActive = expiration > Date()
        } else {
            isActive = true
        }

        onEntitlementChanged?(isActive)
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
