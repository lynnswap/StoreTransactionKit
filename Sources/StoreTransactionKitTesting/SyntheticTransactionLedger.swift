import Foundation
import StoreKit
import StoreTransactionKit

@MainActor
final class SyntheticTransactionLedger: Sendable {
    private var nextTransactionID: UInt64 = 1
    private var registeredSnapshots: [UInt64: StoreTransactionSnapshot] = [:]
    private var activeSnapshot: StoreTransactionSnapshot?

    func snapshots() -> [StoreTransactionSnapshot] {
        if let activeSnapshot {
            [activeSnapshot]
        } else {
            []
        }
    }

    func makeRegisteredSnapshot(
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
        let snapshot = StoreTransactionSnapshot(
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
        precondition(registeredSnapshots[transactionID] == nil)
        registeredSnapshots[transactionID] = snapshot
        return snapshot
    }

    func contains(_ snapshot: StoreTransactionSnapshot) -> Bool {
        registeredSnapshots[snapshot.id] == snapshot
    }

    func activate(_ snapshot: StoreTransactionSnapshot) {
        precondition(
            contains(snapshot),
            "Only a transaction registered by this test harness can become current."
        )
        activeSnapshot = snapshot
    }
}
