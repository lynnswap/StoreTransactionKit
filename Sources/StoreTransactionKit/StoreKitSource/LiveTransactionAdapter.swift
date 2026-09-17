import Foundation
import StoreKit

package enum LiveTransactionAdapter {
    package static func delivery(
        _ result: VerificationResult<Transaction>
    ) -> StoreTransactionDelivery {
        switch result {
        case .verified(let transaction):
            let jwsRepresentation = result.jwsRepresentation
            return .verified(
                ProcessingEnvelope(
                    revision: Data(jwsRepresentation.utf8),
                    value: snapshot(
                        transaction,
                        jwsRepresentation: jwsRepresentation
                    ),
                    finish: {
                        await transaction.finish()
                    }
                ))
        case .unverified(_, let error):
            return .unverified(
                revision: Data(result.jwsRepresentation.utf8),
                error: StoreTransactionVerificationError(
                    underlyingError: error
                ))
        }
    }

    package static func snapshot(
        _ result: VerificationResult<Transaction>
    ) throws(StoreTransactionVerificationError) -> StoreTransactionSnapshot {
        switch result {
        case .verified(let transaction):
            return snapshot(
                transaction,
                jwsRepresentation: result.jwsRepresentation
            )
        case .unverified(_, let error):
            throw StoreTransactionVerificationError(underlyingError: error)
        }
    }

    package static func entitlement(
        _ result: VerificationResult<Transaction>
    ) -> Result<StoreTransactionSnapshot, CurrentEntitlementQueryResult.VerificationFailure> {
        do {
            return .success(try snapshot(result))
        } catch {
            return .failure(
                .init(
                    revision: Data(result.jwsRepresentation.utf8),
                    error: error
                )
            )
        }
    }

    private static func snapshot(
        _ transaction: Transaction,
        jwsRepresentation: String
    ) -> StoreTransactionSnapshot {
        StoreTransactionSnapshot(
            id: transaction.id,
            originalID: transaction.originalID,
            productID: transaction.productID,
            subscriptionGroupID: transaction.subscriptionGroupID,
            productType: transaction.productType,
            environment: transaction.environment,
            offer: transaction.offer,
            storefrontID: transaction.storefront.id,
            storefrontCountryCode: transaction.storefront.countryCode,
            price: transaction.price,
            currency: transaction.currency,
            purchaseDate: transaction.purchaseDate,
            originalPurchaseDate: transaction.originalPurchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            revocationReason: transaction.revocationReason,
            purchasedQuantity: transaction.purchasedQuantity,
            isUpgraded: transaction.isUpgraded,
            ownershipType: transaction.ownershipType,
            reason: transaction.reason,
            appAccountToken: transaction.appAccountToken,
            signedDate: transaction.signedDate,
            jwsRepresentation: jwsRepresentation
        )
    }
}
