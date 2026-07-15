# StoreTransactionKit

StoreTransactionKit moves StoreKit 2 transaction monitoring, verification,
durable processing, and `Transaction.finish()` into one process-owned,
observable store.
It supports iOS 18.4 and later and macOS 15.4 and later.

## Create a Store

Define the entitlement identifiers in the app. A string-backed enum keeps
StoreKit product identifiers typed without requiring a framework protocol.

```swift
import StoreTransactionKit

enum SubscriptionID: String, Hashable, Sendable {
    case monthly = "com.example.subscription.monthly"
    case yearly = "com.example.subscription.yearly"
}

actor PurchaseLedger {
    func apply(_ transaction: StoreTransactionSnapshot) async throws {
        try await database.commitPurchase(
            transactionID: transaction.id,
            productID: transaction.productID
        )
    }
}

actor StoreDiagnostics {
    func record(_ failure: StoreTransactionBackgroundFailure) {
        logger.error("StoreKit background failure: \(failure.underlyingError)")
    }
}

@MainActor
func makeStore(
    ledger: PurchaseLedger,
    diagnostics: StoreDiagnostics
) -> Store<SubscriptionID> {
    Store(
        handleTransaction: { transaction in
            try await ledger.apply(transaction)
        },
        reportFailure: { failure in
            await diagnostics.record(failure)
        }
    )
}
```

`Store` is `@MainActor` and `@Observable`. It starts `Transaction.unfinished`
and `Transaction.updates` monitoring during initialization. Retain one instance
in the application's process-lifetime composition.

`activeEntitlements` contains the app-defined identifiers represented by
StoreKit's current entitlements. `entitlements` contains the complete verified
snapshot, including product identifiers outside `SubscriptionID`.

## Use SubscriptionStoreView

Place the same store in the SwiftUI environment. StoreKit presents and
completes the purchase; the store's transaction listener updates observable
state when the entitlement changes.

```swift
PremiumStoreView()
    .environment(store)
```

```swift
import StoreKit
import SwiftUI

struct PremiumStoreView: View {
    @Environment(Store<SubscriptionID>.self) private var store

    var body: some View {
        VStack {
            if store.activeEntitlements.contains(.yearly) {
                Label("Premium active", systemImage: "checkmark.seal.fill")
            }

            SubscriptionStoreView(
                groupID: "YOUR_SUBSCRIPTION_GROUP_ID"
            )
        }
    }
}
```

No `onInAppPurchaseCompletion` modifier is needed here. By default, successful
StoreKit view purchases are delivered through `Transaction.updates`, which the
store already monitors. A non-`nil` completion action replaces that default;
if you add one, pass its successful `Product.PurchaseResult` to
`store.process(_:)`.

`PurchaseLedger.apply(_:)` must be idempotent because StoreKit delivery is at
least once. It must return only after the business effect is durable. The
store calls `finish()` after that return.

Call `store.restorePurchases()` only from an explicit user action because
`AppStore.sync()` may present authentication UI.

For product merchandising and UI composition, use Apple's
[Getting started with In-App Purchase using StoreKit views](https://developer.apple.com/documentation/storekit/getting-started-with-in-app-purchases-using-storekit-views)
and
[Implementing a store in your app using the StoreKit API](https://developer.apple.com/documentation/storekit/implementing-a-store-in-your-app-using-the-storekit-api).

## License

StoreTransactionKit is available under the MIT License.
