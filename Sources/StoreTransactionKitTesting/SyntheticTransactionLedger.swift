import Foundation
import StoreKit
import StoreTransactionKit

@MainActor
final class SyntheticTransactionLedger: Sendable {
    enum CurrentEntitlementEffect: Equatable, Sendable {
        case none
        case replaceActiveSubscription
    }

    private struct Registration: Sendable {
        let snapshot: StoreTransactionSnapshot
        let currentEntitlementEffect: CurrentEntitlementEffect
    }

    private enum CurrentSubscriptionState: Sendable {
        case empty(latestTransactionID: UInt64?)
        case active(StoreTransactionSnapshot)

        var latestTransactionID: UInt64? {
            switch self {
            case .empty(let latestTransactionID):
                latestTransactionID
            case .active(let snapshot):
                snapshot.id
            }
        }
    }

    private var nextTransactionID: UInt64 = 1
    private var registrations: [UInt64: Registration] = [:]
    private var currentSubscription: CurrentSubscriptionState =
        .empty(latestTransactionID: nil)

    func snapshots() -> [StoreTransactionSnapshot] {
        switch currentSubscription {
        case .empty:
            []
        case .active(let snapshot):
            [snapshot]
        }
    }

    func makeRegisteredSnapshot(
        productID: String,
        productType: Product.ProductType,
        subscriptionGroupID: SubscriptionGroupID?,
        isUpgraded: Bool = false,
        currentEntitlementEffect: CurrentEntitlementEffect
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
            subscriptionGroupID: subscriptionGroupID?.rawValue,
            productType: productType,
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
            isUpgraded: isUpgraded,
            ownershipType: .purchased,
            reason: .purchase,
            appAccountToken: nil,
            signedDate: date,
            jwsRepresentation:
                "StoreTransactionKitTesting.synthetic.\(transactionID)"
        )
        precondition(registrations[transactionID] == nil)
        registrations[transactionID] = Registration(
            snapshot: snapshot,
            currentEntitlementEffect: currentEntitlementEffect
        )
        return snapshot
    }

    func contains(_ snapshot: StoreTransactionSnapshot) -> Bool {
        registrations[snapshot.id]?.snapshot == snapshot
    }

    func applyDeliveryEffect(for snapshot: StoreTransactionSnapshot) {
        guard let registration = registrations[snapshot.id],
            registration.snapshot == snapshot
        else {
            preconditionFailure(
                "Only an exact transaction registered by this test harness can be delivered."
            )
        }
        guard
            registration.currentEntitlementEffect
                == .replaceActiveSubscription
        else {
            return
        }
        guard
            currentSubscription.latestTransactionID.map({
                $0 < snapshot.id
            }) ?? true
        else {
            return
        }
        currentSubscription = .active(snapshot)
    }

    func expireActiveSubscription() -> StoreTransactionSnapshot? {
        guard case .active(let snapshot) = currentSubscription else {
            return nil
        }
        currentSubscription = .empty(latestTransactionID: snapshot.id)
        return snapshot
    }
}
