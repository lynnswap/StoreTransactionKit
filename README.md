# StoreTransactionKit

StoreTransactionKit centralizes verified transaction handling, entitlement
reconciliation, and `Transaction.finish()` authority in one process-owned,
observable store.

## Requirements

- iOS 18.4+
- macOS 15.4+
- Mac Catalyst 18.4+
- tvOS 18.4+
- watchOS 11.4+
- visionOS 2.4+
- Swift 6.3+

## Installation

In Xcode, choose **File > Add Package Dependencies**, enter
`https://github.com/lynnswap/StoreTransactionKit`, and add the
`StoreTransactionKit` library to your app target.

## Quick start

The APIs shown below are proposed for the next beta. The current source does not
implement them yet.

Define the app's entitlements and one App Store Connect auto-renewable
subscription group:

```swift
import StoreTransactionKit

enum SubscriptionEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

enum Plans: AutoRenewableSubscriptionGroup<SubscriptionEntitlement> {
    static let id = SubscriptionGroupID(
        rawValue: "YOUR_SUBSCRIPTION_GROUP_ID"
    )

    enum ProductID: String {
        case tier1_Monthly = "com.example.subscription.tier1.monthly"
        case tier1_Yearly = "com.example.subscription.tier1.yearly"
        case tier2_Monthly = "com.example.subscription.tier2.monthly"
        case tier2_Yearly = "com.example.subscription.tier2.yearly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.tier1_Monthly, entitlement: .tier1)
        StoreSubscription(.tier1_Yearly, entitlement: .tier1)
        StoreSubscription(.tier2_Monthly, entitlement: .tier2)
        StoreSubscription(.tier2_Yearly, entitlement: .tier2)
    }
}

let subscriptionCatalog = AutoRenewableSubscriptionCatalog(Plans.self)
```

Use the subscription group ID and Product IDs exactly as configured in
[App Store Connect][subscription-setup]. Monthly and yearly subscriptions can
grant the same app entitlement.

Create one store at the app's process-lifetime composition root:

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

Read the store directly and gate only the paid feature. Entitlement
availability does not need to block the rest of the UI:

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
            SubscriptionStoreView(groupID: Plans.id.rawValue)
        }
    }
}
```

No `onInAppPurchaseCompletion` modifier is needed for the default StoreKit-view
flow. Successful purchases arrive through `Transaction.updates`, which the
store monitors. Use the same Product IDs in the active `.storekit`
configuration when running local StoreKit tests.

## Entitlement availability

- `activeEntitlements == nil` means no usable entitlement snapshot is
  available. An empty set means the query succeeded and no app entitlement is
  active.
- `entitlementStatus` explains whether the store is loading, failed, ready, or
  using an app-supplied override.
- `isEntitled(to:)` performs exact membership and returns `false` while the
  entitlement set is unavailable.

Keep normal app content usable while the entitlement set is unavailable. Gate
only features that require an active purchase.

## Override entitlements

An app-defined debug, preview, or distribution environment can bypass StoreKit
with an exact entitlement set:

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

The delegate is optional. Supply one only when the app owns an additional
durable transaction effect, handles a product outside the subscription catalog,
or needs background-failure notifications. Without a delegate, automatic
handling finishes only catalog-validated auto-renewable subscriptions.

For policy, redelivery, failure routing, and shutdown contracts, see the
[API design](Docs/AutoRenewableSubscriptionCatalogAPI.md).

## Testing

App and ViewModel tests can use `StoreTransactionKitTesting` without a
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

`purchase(_:,in:)` returns after the resulting entitlement publication, so the
test needs no timing guess. Inject `TransactionStoreTestClock` into the app
component that owns a delay or deadline.

The app-hosted StoreKit integration suite continues to test the live adapter.
See [Tools/TestApp/README.md](Tools/TestApp/README.md) for its scenarios and
command.

## License

StoreTransactionKit is available under the MIT License.

[subscription-setup]: https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions
