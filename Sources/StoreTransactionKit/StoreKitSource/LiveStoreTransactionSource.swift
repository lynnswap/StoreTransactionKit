import StoreKit

package extension StoreTransactionSource {
    static let live = StoreTransactionSource(
        runUpdates: { consume in
            for await result in Transaction.updates {
                await consume(LiveTransactionAdapter.delivery(result))
            }
        },
        runSubscriptionStatusUpdates: { consume in
            for await _ in Product.SubscriptionInfo.Status.updates {
                await consume()
            }
        },
        currentEntitlements: {
            var snapshots: [StoreTransactionSnapshot] = []
            var verificationFailures: [StoreTransactionVerificationError] = []
            for await result in Transaction.currentEntitlements {
                do {
                    snapshots.append(try LiveTransactionAdapter.snapshot(result))
                } catch let error as StoreTransactionVerificationError {
                    verificationFailures.append(error)
                }
            }
            return CurrentEntitlementQueryResult(
                snapshots: snapshots,
                verificationFailures: verificationFailures
            )
        },
        queryUnfinished: {
            var deliveries: [StoreTransactionDelivery] = []
            for await result in Transaction.unfinished {
                deliveries.append(LiveTransactionAdapter.delivery(result))
            }
            return deliveries
        },
        history: { productID in
            var snapshots: [StoreTransactionSnapshot] = []
            for await result in Transaction.all(for: productID) {
                snapshots.append(try LiveTransactionAdapter.snapshot(result))
            }
            return snapshots
        },
        synchronize: {
            try await AppStore.sync()
        },
        purchaseDelivery: { result in
            LiveTransactionAdapter.delivery(result)
        }
    )
}
