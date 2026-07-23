import Foundation
import StoreKit
import StoreTransactionKit

@MainActor
final class SyntheticCurrentEntitlements: Sendable {
    private var nextTransactionID: UInt64 = 1
    private var activeSnapshot: StoreTransactionSnapshot?

    func snapshots() -> [StoreTransactionSnapshot] {
        if let activeSnapshot {
            [activeSnapshot]
        } else {
            []
        }
    }

    func makeSnapshot(
        productID: String,
        subscriptionGroupID: SubscriptionGroupID
    ) -> StoreTransactionSnapshot {
        precondition(
            nextTransactionID < .max,
            "The transaction-store test harness exhausted its transaction identifiers."
        )
        let transactionID = nextTransactionID
        nextTransactionID += 1

        let date = Date(timeIntervalSince1970: TimeInterval(transactionID))
        return StoreTransactionSnapshot(
            id: transactionID,
            originalID: transactionID,
            productID: productID,
            subscriptionGroupID: subscriptionGroupID.rawValue,
            productType: .autoRenewable,
            environment: .xcode,
            offer: nil,
            storefrontID: "143441",
            storefrontCountryCode: "USA",
            price: nil,
            currency: nil,
            purchaseDate: date,
            originalPurchaseDate: date,
            expirationDate: nil,
            revocationDate: nil,
            revocationReason: nil,
            purchasedQuantity: 1,
            isUpgraded: false,
            ownershipType: .purchased,
            reason: .purchase,
            appAccountToken: nil,
            signedDate: date,
            jwsRepresentation:
                "StoreTransactionKitTesting.synthetic.\(transactionID)"
        )
    }

    func replace(with snapshot: StoreTransactionSnapshot) {
        activeSnapshot = snapshot
    }
}
