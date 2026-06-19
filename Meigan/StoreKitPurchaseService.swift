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
    func purchasePro(for userId: UUID) async throws -> Bool
    func restorePurchases(for userId: UUID) async throws -> Bool
    func hasActiveProEntitlement(for userId: UUID) async throws -> Bool
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

    func purchasePro(for userId: UUID) async throws -> Bool {
        if proProduct == nil {
            await loadProducts()
        }

        guard let product = proProduct else {
            throw StoreKitPurchaseError.productNotFound
        }

        let result = try await product.purchase(
            options: [.appAccountToken(userId)]
        )

        switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await handleVerifiedTransaction(transaction, expectedUserId: userId)
                await transaction.finish()
                return true

            case .userCancelled, .pending:
                return false
            
            @unknown default:
                return false
        }
    }

    // MARK: - Restore
    func restorePurchases(for userId: UUID) async throws -> Bool {
        try await AppStore.sync()
        let isPro = try await hasActiveProEntitlement(for: userId)
        onEntitlementChanged?(isPro)
        return isPro
    }

    // MARK: - Entitlements

    func hasActiveProEntitlement(for userId: UUID) async throws -> Bool {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.productID == MeiganProducts.proMonthly else { continue }
            guard transaction.appAccountToken == userId else { continue}

            if let expiration = transaction.expirationDate {
                if expiration > Date() { return true }
            } else {
                // Non-consumable purchase, lifetime access
                return true 
            }
        }
        return false
    }

    // MARK: - Transaction listener (start once at launch)

    var currentUserIdProvider: (() -> UUID)?

    func startTransactionListener() {
        guard transactionListenerTask == nil else { return }

        transactionListenerTask = Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break}
                guard let transaction = try? checkVerified(result) else { continue }
                guard let userId = currentUserIdProvider?() else { continue}

                await handleVerifiedTransaction(transaction, expectedUserId: userId)
                await transaction.finish()
            }
        }
    }

    // MARK: - Private
    private func handleVerifiedTransaction(_ transaction: Transaction, expectedUserId: UUID) async {
        guard transaction.productID == MeiganProducts.proMonthly else { return }
        guard transaction.appAccountToken == expectedUserId else { return }

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
