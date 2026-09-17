import StoreKit

package extension StoreTransactionSource {
    static func live(subscriptionGroupID: SubscriptionGroupID) -> StoreTransactionSource {
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
                var verificationFailures: [CurrentEntitlementQueryResult.VerificationFailure] = []
                for await result in Transaction.currentEntitlements {
                    switch LiveTransactionAdapter.entitlement(result) {
                    case .success(let snapshot):
                        snapshots.append(snapshot)
                    case .failure(let failure):
                        verificationFailures.append(failure)
                    }
                }
                let transactions = CurrentEntitlementQueryResult(
                    snapshots: snapshots,
                    verificationFailures: verificationFailures
                )
                let statuses = try await Product.SubscriptionInfo.status(
                    for: subscriptionGroupID.rawValue
                )
                // Query the managed group through subscription status: on a
                // physical device, Xcode StoreKit Testing can omit an active
                // subscription from currentEntitlements even after relaunch.
                return transactions.replacingSubscriptionGroup(
                    subscriptionGroupID,
                    with: statuses.map { status in
                        (state: status.state, transaction: LiveTransactionAdapter.entitlement(status.transaction))
                    }
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
