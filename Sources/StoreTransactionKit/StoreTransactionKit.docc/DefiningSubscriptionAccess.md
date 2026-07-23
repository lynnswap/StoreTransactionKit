# Defining subscription access

Map the Product IDs in one App Store Connect subscription group to values that
describe access in your app.

## Declare the catalog

An App Store Connect subscription group can contain several service levels and
several durations at each level. App Store Connect numbers service levels from
highest to lowest, so level 1 is the highest. StoreKit owns that upgrade and
downgrade ordering, duration, renewal, and billing state. Your app owns the
access meaning.

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

In this example, `.tier1` and `.tier2` are exact active plan identities. The
catalog doesn't interpret StoreKit's service-level order as app feature
inclusion.

## Merchandise declared products

Pass the same declared Product IDs to StoreKit's subscription view:

```swift
import StoreKit

SubscriptionStoreView(
    productIDs: subscriptionCatalog.productIDs
)
```

This keeps the paywall aligned with the catalog in this binary. A valid
same-group product can still arrive from another device or purchase path. A
non-upgraded unrecognized product remains in the raw projection, grants no
typed access by default, and doesn't by itself make entitlement readiness fail.
See <doc:UnderstandingTransactionHandling> to choose another policy with
``UnrecognizedSubscriptionDelegate``.

## Load product information

The catalog exposes declared Product IDs in declaration order. Load their
current StoreKit metadata for custom merchandising:

```swift
import StoreKit

let loadedProducts = try await Product.products(
    for: subscriptionCatalog.productIDs
)
let productsByID = Dictionary(
    uniqueKeysWithValues: loadedProducts.map { ($0.id, $0) }
)

for productID in subscriptionCatalog.productIDs {
    guard
        let product = productsByID[productID],
        let entitlement = subscriptionCatalog.entitlement(for: productID),
        let subscription = product.subscription
    else {
        continue
    }

    let displayName = product.displayName
    let displayPrice = product.displayPrice
    let groupLevel = subscription.groupLevel
    let period = subscription.subscriptionPeriod
}
```

``AutoRenewableSubscriptionCatalog/entitlement(for:)`` joins a StoreKit
`Product` to the app entitlement declared by this binary.
`Product.SubscriptionInfo` supplies the current group level, period, group
metadata, and offers. It is product metadata rather than part of the verified
``StoreTransactionSnapshot``.

Query current renewal status separately with the same catalog identity:

```swift
let statuses = try await Product.SubscriptionInfo.status(
    for: subscriptionCatalog.subscriptionGroupID.rawValue
)
```

Use these statuses for renewal and billing presentation. Keep
``TransactionStore/activeEntitlements`` as the access source of truth.

## Read access without blocking the UI

``TransactionStore/isEntitled(to:)`` performs exact set membership and returns
`false` while access is unavailable. Derive feature access from the active plan
while keeping ordinary app content usable:

```swift
private var canUsePremiumFeatures: Bool {
    store.isEntitled(to: .tier1)
        || store.isEntitled(to: .tier2)
}

private var canExportPDF: Bool {
    store.isEntitled(to: .tier1)
}
```

Here, tier 1 grants the features shared by both plans and the tier-1-only PDF
export, while tier 2 grants only the shared features. If several screens use the
same inclusion rule, centralize it in the app's ViewModel or feature policy
instead of repeating the membership checks.

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
