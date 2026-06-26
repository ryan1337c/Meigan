import Foundation
import Supabase
import StoreKit

enum SubscriptionValidationService {
    
    // Validates a transaction on the server
    static func validateOnServer(transaction: VerificationResult<Transaction>) async throws {
        let jws = transaction.jwsRepresentation

        struct Body: Encodable { let signedTransaction: String }
        struct Response: Decodable { let tier: String }

        let _: Response = try await supabase.functions.invoke(
            "validate-subscription",
            options: FunctionInvokeOptions(body: Body(signedTransaction: jws))
        )
    }

    // Synchronizes the user's tier from the server
    static func syncTierFromServer() async throws -> SubscriptionTier {
        struct Row: Decodable { let tier: String }

        // Returns an array of rows, we only need the first one since we're using a single-row upsert
        let rows: [Row] = try await supabase.rpc("sync_user_subscription").execute().value

        guard let raw = rows.first?.tier,
              let tier = SubscriptionTier(rawValue: raw) else { return .free }

        return tier
            
    }

}
