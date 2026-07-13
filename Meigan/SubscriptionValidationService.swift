import Foundation
import Supabase
import StoreKit

enum SubscriptionValidationService {
    
    // Validates a transaction on the server
    static func validateOnServer(transaction: VerificationResult<Transaction>) async throws {
        let jws = transaction.jwsRepresentation

        struct Body: Encodable { let signedTransaction: String }
        
        // Define structs for both success and error scenarios
        struct SuccessResponse: Decodable { 
            let tier: String 
            let expiresAt: String? // Added since your backend returns this!
        }
        struct ErrorResponse: Decodable { 
            let error: String 
        }

        do {
            // Attempt the invocation
            let response: SuccessResponse = try await supabase.functions.invoke(
                "validate-subscription",
                options: FunctionInvokeOptions(body: Body(signedTransaction: jws))
            )
            
            print("Successfully validated! Tier: \(response.tier)")
         
            
        } catch { 
            if case FunctionsError.httpError(let code, let data) = error {
                if let serverError = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                    print("Server rejected transaction (\(code)): \(serverError.error)")
                    throw CustomSubscriptionError.overlap(message: serverError.error)
                } else {
                    print("Unknown server error with status: \(code)")
                    throw error
                }
            }
            // Catch standard network/decoding errors
            print("Network or decoding failed: \(error.localizedDescription)")
            throw error
        }
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

    enum CustomSubscriptionError: Error, LocalizedError {
        case overlap(message: String)
        
        var errorDescription: String? {
            switch self {
            case .overlap(let message): return message
            }
        }
    }

}
