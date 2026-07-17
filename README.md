# StoreTransactionKit

StoreTransactionKit moves StoreKit 2 transaction monitoring, verification,
durable processing, and `Transaction.finish()` into one process-owned,
observable store.

## Requirements

- iOS 18.4+
- macOS 15.4+
- Swift 6.3+

## What it owns — and what your app owns

The store owns the durable transaction path for the process lifetime:

- Monitoring: `Transaction.updates`, `Transaction.unfinished` reconciliation,
  and subscription status changes
- Verification: only verified transactions reach your code; unverified
  deliveries surface as thrown errors or reported failures
- Ordering: durable handling first, then `finish()`, with at-least-once
  delivery to an idempotent handler and exact-revision deduplication
- State: the observable current-entitlement projection, restore
  synchronization, background failure delivery, and explicit shutdown

Your app owns everything the user sees and everything it persists:

- Paywall and purchase UI (StoreKit views or `Product.purchase`)
- The durable ledger that the transaction handler writes to
- Subscription status presentation (`Product.SubscriptionInfo.Status`)
- Purchases that begin outside the app (`PurchaseIntent.intents`)

## Quick start

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

`TransactionStore` is `@MainActor` and `@Observable`. It starts monitoring
during initialization. Create the app-owned dependencies once at the
process-lifetime composition root, retain one store with SwiftUI state, and
inject that same instance into the environment:

```swift
import SwiftUI

@main
struct ExampleApp: App {
    @State private var store: TransactionStore<SubscriptionID>

    init() {
        let ledger = PurchaseLedger()
        let diagnostics = StoreDiagnostics()
        _store = State(
            initialValue: makeStore(
                ledger: ledger,
                diagnostics: diagnostics
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            PremiumStoreView()
                .environment(store)
        }
    }
}
```

The view reads the store directly and renders the three entitlement states —
resolving, failed, and resolved:

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

No `onInAppPurchaseCompletion` modifier is needed: successful StoreKit view
purchases arrive through `Transaction.updates`, which the store already
monitors. If you add a non-`nil` completion action, it replaces that default
*and* StoreKit's failure alert — pass each `.success` value to
`store.process(_:)` and own `.failure` presentation yourself.

## The callback contracts

`handleTransaction` owns the app's durable transaction correctness:

- **Be idempotent.** Delivery is at least once; key the ledger on transaction
  identity plus the business event it applies.
- **Treat purchase and revocation as distinct events.** A refund or
  family-sharing revocation arrives as the same transaction with
  `revocationDate` set; transaction ID alone is not a sufficient key.
- **Return only after the business effect is durable.** The store calls
  `finish()` after the handler returns. Throwing keeps the transaction
  unfinished, and a later refresh retries it.
- **Never call back into the same store** from `handleTransaction` or
  `reportFailure`, even through an awaited detached task — doing so creates a
  dependency cycle with the work being handled.

`reportFailure` is also a liveness boundary. StoreTransactionKit delivers
admitted failures serially with backpressure and waits for each callback to
return; `close()` waits for those callbacks too. Record or enqueue the failure
promptly instead of performing work that can wait indefinitely.

Both callback contracts are documented on `TransactionStore.init`.

## How entitlement state behaves

- `activeEntitlements` is `nil` until the first entitlement query resolves; an
  empty set means the query resolved and no known identifier matched.
- Startup and every refresh reconcile `Transaction.unfinished` — including
  consumables — before publishing state. A handler failure fails that refresh;
  the next refresh retries the unfinished work.
- Transactions superseded by a subscription upgrade stay in `entitlements` but
  leave `activeEntitlements`.
- Unverified current-entitlement elements are omitted and reported to
  `reportFailure` with source `.currentEntitlementVerification`.
- Identifiers map 1:1 to product IDs. Gate access on the tier set, or use
  `StoreTransactionSnapshot.subscriptionGroupID` to grant at
  subscription-group granularity.

For the full delivery, reconciliation, and failure-reporting model, see
[Understanding transaction handling][understanding].

## Beyond the basics

- **Custom purchase UI** — load products and purchase with StoreKit, then pass
  the `Product.PurchaseResult` to `store.process(_:)`. `.pending` outcomes
  arrive later through the handler.
- **Restore** — call `store.restorePurchases()` only from an explicit user
  action; `AppStore.sync()` presents authentication UI, and
  `StoreKitError.userCancelled` is a normal outcome, not a diagnostic failure.
- **Promoted purchases and win-back offers** — the app owns
  `PurchaseIntent.intents`: complete each intent's purchase and pass the
  result to `store.process(_:)`.
- **Renewal, grace-period, and billing-retry UI** — read
  `Product.SubscriptionInfo.Status` directly; the store owns the durable
  transaction path, not subscription status presentation.

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

[understanding]: https://lynnswap.github.io/StoreTransactionKit/documentation/storetransactionkit/understandingtransactionhandling
