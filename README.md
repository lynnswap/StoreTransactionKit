# StoreTransactionKit

StoreTransactionKit moves StoreKit 2 transaction monitoring, verification,
durable processing, and `Transaction.finish()` into one process-owned,
observable store.
It supports iOS 18.4 and later and macOS 15.4 and later.

## Create a TransactionStore

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
        if let revocationDate = transaction.revocationDate {
            try await database.revokePurchase(
                transactionID: transaction.id,
                productID: transaction.productID,
                signedDate: transaction.signedDate,
                revocationDate: revocationDate
            )
        } else {
            try await database.commitPurchase(
                transactionID: transaction.id,
                productID: transaction.productID,
                signedDate: transaction.signedDate
            )
        }
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
) -> TransactionStore<SubscriptionID> {
    TransactionStore(
        handleTransaction: { transaction in
            try await ledger.apply(transaction)
        },
        reportFailure: { failure in
            await diagnostics.record(failure)
        }
    )
}
```

`TransactionStore` is `@MainActor` and `@Observable`. It monitors
`Transaction.unfinished`, `Transaction.updates`, and subscription status
changes during initialization. Retain one instance in the application's
process-lifetime composition.

Startup and each entitlement refresh reconcile `Transaction.unfinished`
before publishing entitlement state. Every verified delivery is durably
handled, including consumables. If the handler fails, startup or the refresh
fails, the transaction remains unfinished, and a later refresh retries it.
An unverified unfinished delivery is sent to `reportFailure` with source
`.unfinished`.

`activeEntitlements` contains the app-defined identifiers represented by
StoreKit's current entitlements. It is `nil` while the initial entitlement
query is unresolved and becomes a non-`nil` empty set when no known
identifier matches a current entitlement. A subscription superseded by an
upgrade is excluded from this set. `entitlements` contains the complete
verified snapshot, including superseded transactions and product identifiers
outside `SubscriptionID`. Use `StoreTransactionSnapshot.subscriptionGroupID`
when the app grants access at subscription-group rather than product-tier
granularity. A current-entitlement element that StoreKit can't verify is
omitted from the projection and delivered to `reportFailure` with source
`.currentEntitlementVerification`.

For renewal dates, grace periods, billing retry, and expiration messaging,
read `Product.SubscriptionInfo.Status` directly. `TransactionStore` owns the
durable transaction path and current-entitlement projection, not subscription
status presentation.

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
    @Environment(TransactionStore<SubscriptionID>.self) private var store
    @State private var refreshError: (any Error)?

    var body: some View {
        VStack {
            if let activeEntitlements = store.activeEntitlements {
                if activeEntitlements.contains(.monthly)
                    || activeEntitlements.contains(.yearly)
                {
                    Label("Premium active", systemImage: "checkmark.seal.fill")
                }
            } else if let error = refreshError ?? store.startupError {
                Text(error.localizedDescription)
                Button("Retry") {
                    Task {
                        do {
                            try await store.refreshEntitlements()
                            refreshError = nil
                        } catch {
                            refreshError = error
                        }
                    }
                }
            } else {
                ProgressView()
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
if you add one, pass each `.success` value (the `Product.PurchaseResult`) to
`store.process(_:)`. The action also replaces StoreKit's default failure alert,
so it must own `.failure` presentation or diagnostics.

StoreTransactionKit exposes an at-least-once handler-delivery contract, so
`PurchaseLedger.apply(_:)` must be idempotent. It must return only after the
business effect is durable. The store calls `finish()` after that return. Treat
purchase and revocation revisions as distinct durable business events;
transaction ID alone is not a sufficient idempotency key for both. The handler
must not call methods on the same store, including through an awaited detached
task, because that creates a dependency cycle with the transaction being
handled.

Apps that support promoted purchases or applicable win-back flows own
`PurchaseIntent.intents`: complete each intent's product purchase and pass its
result to `store.process(_:)`.

Call `store.restorePurchases()` only from an explicit user action because
`AppStore.sync()` presents authentication UI. Treat `StoreKitError.userCancelled`
as a normal user outcome rather than a diagnostic failure.

For product merchandising and UI composition, use Apple's
[Getting started with In-App Purchase using StoreKit views](https://developer.apple.com/documentation/storekit/getting-started-with-in-app-purchases-using-storekit-views)
and
[Implementing a store in your app using the StoreKit API](https://developer.apple.com/documentation/storekit/implementing-a-store-in-your-app-using-the-storekit-api).

## Testing

The app-hosted StoreKit integration suite runs with `xcodebuild`. See
[Tools/TestApp/README.md](Tools/TestApp/README.md) for the scenarios and
command.

## License

StoreTransactionKit is available under the MIT License.
