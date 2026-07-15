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
                StoreTransactionVerificationError(
                    underlyingError: error
                ))
        }
    }

    package static func snapshot(
        _ result: VerificationResult<Transaction>
    ) throws -> StoreTransactionSnapshot {
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
