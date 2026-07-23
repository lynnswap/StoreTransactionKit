import StoreKit

package extension StoreTransactionSource {
    static var live: StoreTransactionSource {
        StoreTransactionSource(
            runUpdates: { beginIteration, consume in
                var iterator = Transaction.updates.makeAsyncIterator()
                while let lease = beginIteration() {
                    defer { lease.end() }
                    guard let result = await iterator.next() else { return }
                    await consume(LiveTransactionAdapter.delivery(result))
                }
            },
            runSubscriptionStatusUpdates: { beginIteration, consume in
                var iterator = Product.SubscriptionInfo.Status.updates
                    .makeAsyncIterator()
                while let lease = beginIteration() {
                    defer { lease.end() }
                    guard await iterator.next() != nil else { return }
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
}
