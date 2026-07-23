# Defining subscription access

Map the Product IDs in one App Store Connect subscription group to values that
describe access in your app.

## Declare the catalog

An App Store Connect subscription group can contain several service levels and
several durations at each level. StoreKit owns group-level ordering, duration,
renewal, and billing state. Your app owns the access meaning.

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

    enum ProductID: String, Hashable, Sendable {
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

Use the group ID and Product ID raw values exactly as configured in App Store
Connect. ``AutoRenewableSubscriptionGroup/subscriptions`` is the complete
entitlement mapping known to this binary; it isn't a promise that the live
subscription group contains no other Product IDs. A case that is present only
in `ProductID` doesn't grant typed access. The catalog requires at least one
product, nonempty raw identifiers, and no duplicate raw Product IDs. Several
products may grant the same entitlement.

The compiler keeps group-specific Product IDs and app entitlements typed. At
runtime, the catalog also validates each matching transaction's auto-renewable
product type and subscription group before publishing access.

## Merchandise declared products

Pass the same declared Product IDs to StoreKit's subscription view:

```swift
import StoreKit

SubscriptionStoreView(
    productIDs: Plans.subscriptions.map(\.id.rawValue)
)
```

This keeps the paywall aligned with the catalog in this binary. A valid
same-group product can still arrive from another device or purchase path. An
unrecognized product remains in the raw projection, grants no typed access by
default, and doesn't by itself make entitlement readiness fail. See
<doc:UnderstandingTransactionHandling> to choose another policy with
``UnrecognizedSubscriptionDelegate``.

## Read access without blocking the UI

``TransactionStore/isEntitled(to:)`` performs exact set membership and returns
`false` while access is unavailable. Keep ordinary app content usable and gate
only the paid feature:

```swift
private var canExportPDF: Bool {
    store.isEntitled(to: .tier1)
}
```

Use ``TransactionStore/entitlementStatus`` only when the interface needs to
explain why access is unavailable. In `.ready`, an empty
``TransactionStore/activeEntitlements`` set means the query succeeded and no
declared entitlement is active. In `.loading` or `.failed`, the set is `nil`.

## Override access at composition time

For a preview, debug build, UI test, or app-defined distribution environment,
create a StoreKit-free store with an exact entitlement set:

```swift
let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog,
    overridingEntitlements: [
        SubscriptionEntitlement.tier1,
        .tier2,
    ]
)
```

The app owns the condition selecting this initializer. An empty sequence is an
authoritative override with no access. Override mode starts no StoreKit work,
keeps raw entitlements `nil`, and rejects StoreKit-backed operations.
