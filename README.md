# StoreTransactionKit

StoreTransactionKit moves StoreKit 2 transaction monitoring, verification,
durable processing, and `Transaction.finish()` into one process-owned,
observable store.

## Requirements

- iOS 18.4+
- macOS 15.4+
- Mac Catalyst 18.4+
- tvOS 18.4+
- watchOS 11.4+
- visionOS 2.4+
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

- Paywall and purchase UI (StoreKit views or the platform-appropriate
  StoreKit purchase action)
- The durable ledger that the transaction handler writes to
- Subscription status presentation (`Product.SubscriptionInfo.Status`)
- Purchases that begin outside the app on platforms that provide
  `PurchaseIntent.intents`

## Quick start

Define the app entitlements, then describe one App Store Connect subscription
group with its Product IDs:

```swift
import StoreTransactionKit

enum SubscriptionEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

enum Plans: SubscriptionGroup {
    static let id = SubscriptionGroupID(
        rawValue: "YOUR_SUBSCRIPTION_GROUP_ID"
    )

    enum ProductID: String, CaseIterable {
        case tier1_Monthly = "com.example.subscription.tier1.monthly"
        case tier1_Yearly = "com.example.subscription.tier1.yearly"
        case tier2_Monthly = "com.example.subscription.tier2.monthly"
        case tier2_Yearly = "com.example.subscription.tier2.yearly"
    }

    static func entitlement(
        for productID: ProductID
    ) -> SubscriptionEntitlement {
        switch productID {
        case .tier1_Monthly, .tier1_Yearly:
            .tier1

        case .tier2_Monthly, .tier2_Yearly:
            .tier2
        }
    }
}

let subscriptionCatalog = SubscriptionCatalog(Plans.self)

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
) -> TransactionStore<SubscriptionEntitlement> {
    TransactionStore(
        subscriptionCatalog: subscriptionCatalog,
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
import StoreTransactionKit
import SwiftUI

@main
struct ExampleApp: App {
    @State private var store: TransactionStore<SubscriptionEntitlement>

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
            NavigationStack {
                ContentView()
            }
            .environment(store)
        }
    }
}
```

Read the store from the environment and gate premium features without making
the rest of the UI depend on entitlement availability:

```swift
import StoreKit
import StoreTransactionKit
import SwiftUI

struct ContentView: View {
    @Environment(TransactionStore<SubscriptionEntitlement>.self) private var store
    @State private var isShowingPaywall = false

    private var canExportPDF: Bool {
        store.isEntitled(to: .tier1)
    }

    var body: some View {
        List {
            Section {
                NavigationLink("All notes") {
                    NotesView()
                }
            }

            Section {
                Button("Export as PDF") {
                    exportPDF()
                }
                .disabled(!canExportPDF)

                Button("Plans and subscriptions") {
                    isShowingPaywall = true
                }
            } header: {
                Text("Premium")
            }
        }
        .sheet(isPresented: $isShowingPaywall) {
            SubscriptionStoreView(
                groupID: Plans.id.rawValue
            )
        }
    }
}
```

### Connect the identifiers

Replace `Plans.id` and the nested Product ID raw values with the identifiers
configured in [App Store Connect][subscription-setup]. Map monthly and yearly
products that grant the same access level to the same app entitlement. StoreKit
remains the source of truth for levels and durations.

For local StoreKit Testing, use the same values in the active `.storekit`
configuration. See [Setting up StoreKit Testing in Xcode][storekit-testing].

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

## How entitlement availability behaves

- `entitlementStatus` is `.loading` before the first readiness result,
  `.failed(error)` when no usable catalog projection is available, and `.ready`
  when raw and typed entitlement state is available.
- `activeEntitlements` is `nil` while `entitlementStatus` is `.loading` or
  `.failed`. When the status is `.ready`, an empty set means no catalog
  entitlement is active.
- Gate paid features with `isEntitled(to:)` without blocking the surrounding UI.
  Consult `entitlementStatus` only when the app needs to explain why the
  entitlement set is unavailable.
- A successful refresh after `.failed` publishes `.ready` and the new active
  entitlement set. A background query or transaction-handler failure after
  `.ready` preserves the last active set and reports the failure through
  `reportFailure`.
- A verified catalog mismatch fails closed: it changes the status to `.failed`
  and clears both entitlement projections instead of preserving stale access.
- Startup and every refresh reconcile `Transaction.unfinished` — including
  consumables — before publishing state. A handler failure fails that refresh;
  the next refresh retries the unfinished work.
- Transactions superseded by a subscription upgrade stay in `entitlements` but
  don't appear in `activeEntitlements`.
- Unverified current-entitlement elements are omitted and reported to
  `reportFailure` with source `.currentEntitlementVerification`.
- Product IDs mapped to the same app entitlement appear as the same typed value.
- `SubscriptionCatalog` maps auto-renewable subscriptions only. Other product
  types don't belong to subscription groups; consumables remain part of
  transaction handling and never appear in current entitlements.

For the full delivery, reconciliation, and failure-reporting model, see
[Understanding transaction handling][understanding].

## Beyond the basics

- **Custom purchase UI** — load products and start the purchase with StoreKit
  views, SwiftUI's `PurchaseAction`, or the platform-appropriate `Product`
  purchase API. Pass the resulting `Product.PurchaseResult` to
  `store.process(_:)`; `.pending` outcomes arrive later through the handler.
- **Restore** — call `store.restorePurchases()` only from an explicit user
  action; `AppStore.sync()` presents authentication UI, and
  `StoreKitError.userCancelled` is a normal outcome, not a diagnostic failure.
- **Promoted purchases and win-back offers** — on platforms that provide
  `PurchaseIntent.intents`, the app completes each intent's purchase and
  passes the result to `store.process(_:)`.
- **Renewal, grace-period, and billing-retry UI** — read
  `Product.SubscriptionInfo.Status` directly; the store owns the durable
  transaction path, not subscription status presentation.

For product merchandising and UI composition, use Apple's
[Getting started with In-App Purchase using StoreKit views](https://developer.apple.com/documentation/storekit/getting-started-with-in-app-purchases-using-storekit-views)
and
[Implementing a store in your app using the StoreKit API](https://developer.apple.com/documentation/storekit/implementing-a-store-in-your-app-using-the-storekit-api).
Apple's
[purchase API guidance](https://developer.apple.com/documentation/storekit/product/purchase(options:))
explains which purchase entry point to use for each UI framework and platform.

## API design

See [Subscription catalog API design](Docs/SubscriptionCatalogAPI.md) for the
proposed public interface, validation rules, ownership boundaries, and state
transition contract behind the Quick start.

## Testing

The app-hosted StoreKit integration suite runs with `xcodebuild`. See
[Tools/TestApp/README.md](Tools/TestApp/README.md) for the scenarios and
command.

## License

StoreTransactionKit is available under the MIT License.

[understanding]: https://lynnswap.github.io/StoreTransactionKit/documentation/storetransactionkit/understandingtransactionhandling
[subscription-setup]: https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions
[storekit-testing]: https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode
