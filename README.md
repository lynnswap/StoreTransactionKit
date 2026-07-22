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

Define typed identifiers whose raw values exactly match the Product IDs in App
Store Connect:

```swift
import StoreTransactionKit

enum SubscriptionID: String, Hashable, Sendable {
    case monthly = "com.example.subscription.monthly"
    case yearly = "com.example.subscription.yearly"
}
```

Create one store at the app's process-lifetime composition root. In this
subscription-only example, StoreKit's current-entitlement state is the complete
app effect. If the app also persists an effect, the transaction handler returns
only after that work is complete. The failure handler records failures owned by
background work:

```swift
import StoreTransactionKit
import OSLog
import SwiftUI

@main
struct ExampleApp: App {
    @State private var store: TransactionStore<SubscriptionID>

    init() {
        let logger = Logger(
            subsystem: "com.example.app",
            category: "StoreKit"
        )
        _store = State(
            initialValue: TransactionStore(
                handleTransaction: { _ in },
                reportFailure: { failure in
                    logger.error(
                        "StoreKit background failure: \(failure.underlyingError)"
                    )
                }
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

Read the store directly from the environment. Entitlement availability does not
need to block the rest of the UI:

```swift
import StoreKit
import StoreTransactionKit
import SwiftUI

struct ContentView: View {
    @Environment(TransactionStore<SubscriptionID>.self) private var store
    @State private var isShowingPaywall = false

    private var hasPremium: Bool {
        store.activeEntitlements?
            .isDisjoint(with: [.monthly, .yearly]) == false
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
                .disabled(!hasPremium)

                Button("Plans and subscriptions") {
                    isShowingPaywall = true
                }
            } header: {
                Text("Premium")
            }
        }
        .sheet(isPresented: $isShowingPaywall) {
            SubscriptionStoreView(
                groupID: "YOUR_SUBSCRIPTION_GROUP_ID"
            )
        }
    }
}
```

Use the subscription group ID from App Store Connect for
`SubscriptionStoreView`. Use the same Product IDs in the app and in the active
`.storekit` configuration when running local StoreKit tests.

No `onInAppPurchaseCompletion` modifier is needed for the default StoreKit-view
flow: successful purchases arrive through `Transaction.updates`, which the store
monitors. If you supply a completion action, pass each successful result to
`store.process(_:)` and present failures yourself.

## Entitlement availability

- `activeEntitlements == nil` means no entitlement query has succeeded yet. An
  empty set means the query succeeded and none of the typed Product IDs is
  active.
- `startupError` describes a failed initial readiness attempt. The store keeps
  monitoring, and a later successful `refreshEntitlements()` clears it.
- Transactions superseded by a subscription upgrade remain in `entitlements`
  but are excluded from `activeEntitlements`.

Keep normal app content usable while the entitlement set is unavailable. Gate
only the features that require an active purchase.

## Transaction handling

StoreTransactionKit may present the same verified transaction revision to
`handleTransaction` more than once. Make the handler idempotent and return only
after its app-owned business effect is durable; the store calls `finish()` after
the handler succeeds. `reportFailure` receives failures owned by background
work. Neither callback may start another operation on the same store.

For the delivery, reconciliation, restore, shutdown, and failure-routing
contracts, see
[Understanding transaction handling][understanding].

## Testing

The app-hosted StoreKit integration suite runs with `xcodebuild`. See
[Tools/TestApp/README.md](Tools/TestApp/README.md) for its scenarios and command.

## License

StoreTransactionKit is available under the MIT License.

[understanding]: https://lynnswap.github.io/StoreTransactionKit/documentation/storetransactionkit/understandingtransactionhandling
