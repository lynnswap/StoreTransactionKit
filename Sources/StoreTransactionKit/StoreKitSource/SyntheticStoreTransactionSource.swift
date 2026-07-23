import Foundation
import StoreKit

package struct SyntheticStoreTransactionSource: Sendable {
    package let source: StoreTransactionSource

    package init(
        currentEntitlements:
            @escaping @Sendable () async -> [StoreTransactionSnapshot]
    ) {
        source = StoreTransactionSource(
            runUpdates: { _, _ in },
            runSubscriptionStatusUpdates: { _, _ in },
            currentEntitlements: {
                CurrentEntitlementQueryResult(
                    snapshots: await currentEntitlements(),
                    verificationFailures: []
                )
            },
            queryUnfinished: { [] },
            history: { _ in preconditionFailure() },
            synchronize: { preconditionFailure() },
            purchaseDelivery: { _ in preconditionFailure() }
        )
    }
}

package extension StoreTransactionDelivery {
    static func synthetic(
        snapshot: StoreTransactionSnapshot,
        acknowledge: @escaping @Sendable () async -> Void
    ) -> StoreTransactionDelivery {
        .verified(
            ProcessingEnvelope(
                revision: Data(snapshot.jwsRepresentation.utf8),
                value: snapshot,
                finish: acknowledge
            )
        )
    }
}
