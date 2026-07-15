import StoreKit

package extension StoreTransactionSource {
    static let live = StoreTransactionSource(
        runUpdates: { consume in
            for await result in Transaction.updates {
                await consume(LiveTransactionAdapter.delivery(result))
            }
        },
        runUnfinished: { consume in
            for await result in Transaction.unfinished {
                await consume(LiveTransactionAdapter.delivery(result))
            }
        },
        currentEntitlements: {
            var snapshots: [StoreTransactionSnapshot] = []
            for await result in Transaction.currentEntitlements {
                snapshots.append(try LiveTransactionAdapter.snapshot(result))
            }
            return snapshots
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
