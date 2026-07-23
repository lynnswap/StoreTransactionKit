# Testing subscription access

Drive the production transaction and entitlement pipeline without a `.storekit`
configuration.

## Add the testing product

Keep the production target dependent only on `StoreTransactionKit`. Add both
`StoreTransactionKit` and `StoreTransactionKitTesting` to the test target, then
import both modules explicitly:

```swift
import StoreTransactionKit
import StoreTransactionKitTesting
import Testing
```

The testing product depends on the production module internally, but does not
re-export it. Explicit imports keep production and test-only dependencies clear.

## Drive a typed purchase

```swift
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

The scoped harness starts with a ready empty entitlement set and closes its
store before returning or throwing. `purchase(_:,in:)` validates the supplied
group declaration and Product ID before admission, then returns after policy,
synthetic acknowledgement, reconciliation, and observable-state publication.
No fixed delay or global “idle” wait is needed.

A later purchase in the same group replaces the active synthetic product. The
harness models immediate current access; it does not simulate renewal timing,
billing retry, upgrade scheduling, expiration, or revocation.

## Exercise an unrecognized subscription

Create an undeclared same-group revision separately from delivering it. The
split lets a test replay the exact revision and verify both successful policy
caching and retry after a thrown decision:

```swift
actor LegacyPlanDelegate:
    UnrecognizedSubscriptionDelegate<SubscriptionEntitlement>
{
    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws
        -> UnrecognizedSubscriptionPolicy<SubscriptionEntitlement>
    {
        .treatAs(.tier1)
    }
}

let delegate = LegacyPlanDelegate()

try await withTransactionStoreTestHarness(
    subscriptionCatalog: subscriptionCatalog,
    unrecognizedSubscriptionDelegate: delegate
) { harness in
    let transaction = try harness.makeUnrecognizedSubscription(
        productID: "com.example.subscription.tier1.weekly",
        in: Plans.self
    )

    let outcome = try await harness.deliver(transaction)

    #expect(outcome == .completed(transaction))
    #expect(harness.store.isEntitled(to: .tier1))
}
```

`purchase(_:,in:)` remains the typed shortcut for a catalog-declared product.
`deliver(_:)` accepts only an exact synthetic snapshot registered by that
harness. Replaying an older revision does not replace a later synthetic
subscription that is already current.

The returned ``StoreTransactionSnapshot`` is synthetic. Its
``StoreTransactionSnapshot/jwsRepresentation`` is a deterministic sentinel, not
a signed JWS, and its transaction identifier is local to that harness. Use
app-hosted StoreKit tests for verification, live adapter behavior, StoreKit Test
sessions, renewals, restore UI, history, and revocation.

## Control consumer-owned time

The harness transaction pipeline has no delay or retry timer. Inject
`TransactionStoreTestClock` into the app component that owns time, such as a
ViewModel or delegate, and advance it explicitly. A harness purchase receipt
still marks entitlement publication; clock advancement alone does not imply
that transaction work is complete.

```swift
final class DelayedTransactionDelegate: TransactionStoreDelegate {
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        try await clock.sleep(for: .seconds(30))
        return .finish
    }
}

let clock = TransactionStoreTestClock()
let delegate = DelayedTransactionDelegate(clock: clock)

try await withTransactionStoreTestHarness(
    subscriptionCatalog: subscriptionCatalog,
    delegate: delegate
) { harness in
    let viewModel = NotesViewModel(store: harness.store)
    let purchase = Task { @MainActor in
        try await harness.purchase(
            .tier1_Monthly,
            in: Plans.self
        )
    }

    try await clock.waitUntilPendingSleepCount(reaches: 1)
    #expect(!viewModel.canExportPDF)

    clock.advance(by: .seconds(30))
    try await purchase.value

    #expect(viewModel.canExportPDF)
}
```

`waitUntilPendingSleepCount(reaches:)` is a continuation-backed registration
barrier, so the test needs neither a fixed delay nor guessed `Task.yield()`
counts.
