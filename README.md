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
- Verification: only verified transactions reach policy code; direct failures
  throw, and an optional delegate can receive background failures
- Ordering: verification, an optional app policy decision, then `finish()` only
  when permitted. A bounded process-local cache suppresses recent completed
  revisions, while unfinished decisions are coalesced only through their causal
  attempt.
- State: the observable current-entitlement projection, restore
  synchronization, background failure delivery, and explicit shutdown

Your app owns everything the user sees and everything it persists:

- Paywall and purchase UI (StoreKit views or the platform-appropriate
  StoreKit purchase action)
- Any app-specific durable ledger used by a transaction delegate
- Subscription status presentation (`Product.SubscriptionInfo.Status`)
- Purchases that begin outside the app on platforms that provide
  `PurchaseIntent.intents`

## Quick start

The API in this Quick start is proposed for the next beta and is not implemented
in the current source yet.

Define the app entitlements, then describe one App Store Connect auto-renewable
subscription group with its Product IDs:

```swift
import StoreTransactionKit

enum SubscriptionEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

enum Plans: AutoRenewableSubscriptionGroup {
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

let subscriptionCatalog = AutoRenewableSubscriptionCatalog(Plans.self)
```

`TransactionStore` is `@MainActor` and `@Observable`. It starts monitoring
during initialization. Create one store at the process-lifetime composition
root, retain it with SwiftUI state, and inject that same instance into the
environment:

```swift
import StoreTransactionKit
import SwiftUI

@main
struct ExampleApp: App {
    @State private var store: TransactionStore<SubscriptionEntitlement>

    init() {
        _store = State(
            initialValue: TransactionStore(
                subscriptionCatalog: subscriptionCatalog
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
owns upgrade and downgrade ordering and each product's renewal period; the
catalog owns the app-access meaning of each Product ID.

For local StoreKit Testing, use the same values in the active `.storekit`
configuration. See [Setting up StoreKit Testing in Xcode][storekit-testing].

No `onInAppPurchaseCompletion` modifier is needed: successful StoreKit view
purchases arrive through `Transaction.updates`, which the store already
monitors. If you add a non-`nil` completion action, it replaces that default
*and* StoreKit's failure alert — pass each `.success` value to
`store.process(_:)` and own `.failure` presentation yourself.

## Override entitlements

For previews, internal builds, or other app-defined environments that should
bypass StoreKit, provide the exact app entitlements to enable:

```swift
let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog,
    overridingEntitlements: [
        SubscriptionEntitlement.tier1,
        .tier2,
    ]
)
```

## Transaction delegate

Without a delegate, `.automatic` handling finishes only catalog-validated
auto-renewable subscriptions. Supply a delegate when the app handles other
product types, applies another durable effect, or needs background diagnostics:

```swift
final class AppTransactionDelegate: TransactionStoreDelegate {
    func transactionStore(
        decidePolicyFor transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        guard transaction.productType == .consumable else {
            return .automatic
        }

        try await persist(transaction)
        return .finish
    }

    func transactionStore(
        didFailWith failure: StoreTransactionBackgroundFailure
    ) async {
        await record(failure)
    }
}

let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog,
    delegate: AppTransactionDelegate()
)
```

Both delegate methods are optional through default implementations. The decision
defaults to `.automatic`; the failure notification defaults to a no-op.

When the app implements `transactionStore(decidePolicyFor:)`, it owns the
durable correctness of every non-automatic decision:

- **Be idempotent.** Delivery is at least once; key the ledger on transaction
  identity plus the business event it applies.
- **Treat purchase and revocation as distinct events.** A refund or
  family-sharing revocation arrives as the same transaction with
  `revocationDate` set; transaction ID alone is not a sufficient key.
- **Return `.finish` only after the business effect is durable.** The store then
  calls `finish()`. Return `.keepUnfinished` only after deliberately choosing
  to leave the transaction eligible for a later attempt; throw when neither
  decision can be completed.
- **Don't start another operation on the same store** from either delegate
  method, even through an awaited detached task. Calling `process(_:)`,
  `refreshEntitlements()`, `history(for:)`, `restorePurchases()`, or `close()`
  there can create a dependency cycle with the work being handled. The store
  retains its delegate, so any delegate reference back to the store must also be
  weak.

`.automatic` is not unconditional finish: a catalog mismatch fails before the
delegate is called, and a catalog-external product fails as unhandled unless the
delegate explicitly decides how to process it.

`transactionStore(didFailWith:)` is a notification. Its return cannot change the
transaction decision.

The full decision, redelivery, and failure-routing contracts are documented in
the [API design](Docs/AutoRenewableSubscriptionCatalogAPI.md).

## How entitlement availability behaves

- A live store reports `.loading` before the first readiness result,
  `.failed(error)` when no usable catalog projection is available, and `.ready`
  when raw and typed entitlement state is available. A store created with
  `overridingEntitlements` reports `.overridden` immediately.
- `activeEntitlements` is `nil` while `entitlementStatus` is `.loading` or
  `.failed`. It is non-`nil` for `.ready` and `.overridden`; an empty set means
  no app entitlement is active.
- `entitlements` contains a verified StoreKit snapshot only for `.ready`. It is
  `nil` in override mode because an override does not invent StoreKit
  transactions.
- Gate paid features with `isEntitled(to:)` without blocking the surrounding UI.
  The query checks exact set membership in both `.ready` and `.overridden`.
  Consult `entitlementStatus` only when the app needs to explain where the
  entitlement set came from or why it is unavailable.
- A successful refresh after `.failed` publishes `.ready` and the new active
  entitlement set. A background query or transaction-handling error after
  `.ready` preserves the last active set and reports the failure through
  `transactionStore(didFailWith:)`.
- A verified catalog mismatch fails closed: it changes the status to `.failed`
  and clears both entitlement projections instead of preserving stale access.
- Startup and every refresh reconcile `Transaction.unfinished` — including
  consumables — before publishing state. A transaction-handling error fails that
  refresh; the next refresh retries the unfinished work.
- Transactions superseded by a subscription upgrade stay in `entitlements` but
  don't appear in `activeEntitlements`.
- Unverified current-entitlement elements are omitted and reported to
  `transactionStore(didFailWith:)` with source
  `.currentEntitlementVerification`.
- Product IDs mapped to the same app entitlement appear as the same typed value.
- `AutoRenewableSubscriptionCatalog` maps auto-renewable subscriptions only.
  Other product types don't belong to subscription groups; consumables remain
  part of transaction handling and never appear in current entitlements.

## Beyond the basics

- **Custom purchase UI** — load products and start the purchase with StoreKit
  views, SwiftUI's `PurchaseAction`, or the platform-appropriate `Product`
  purchase API. Pass the resulting `Product.PurchaseResult` to
  `store.process(_:)`; after `.pending`, a later completion may arrive through
  transaction monitoring and the delegate decision path.
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

See [StoreTransactionKit API design](Docs/AutoRenewableSubscriptionCatalogAPI.md)
for the proposed public interface, validation rules, ownership boundaries, and
state transition contract behind the Quick start.

## Testing

App and ViewModel tests can use `StoreTransactionKitTesting` without creating a
`.storekit` configuration:

```swift
import StoreTransactionKitTesting
import Testing

@Test
@MainActor
func subscriptionUpdatesViewModel() async throws {
    try await withTransactionStoreTestHarness(
        subscriptionCatalog: subscriptionCatalog
    ) { harness in
        let viewModel = NotesViewModel(store: harness.store)

        #expect(!viewModel.canExportPDF)

        try await harness.purchase(
            .tier1_Monthly,
            in: Plans.self
        )

        #expect(viewModel.canExportPDF)
    }
}
```

`purchase(_:,in:)` returns after the policy decision, reconciliation, catalog
projection, and the `@MainActor` store publication it caused, so this test does
not need a Clock. Time-driven scenarios inject `TransactionStoreTestClock` into
the app component that owns the delay or deadline.

The harness tests app state and the StoreTransactionKit pipeline. The separate
app-hosted StoreKit integration suite continues to test the live StoreKit
adapter with `xcodebuild` and a shared configuration. See
[Tools/TestApp/README.md](Tools/TestApp/README.md) for its scenarios and command.

## License

StoreTransactionKit is available under the MIT License.

[subscription-setup]: https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions
[storekit-testing]: https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode
