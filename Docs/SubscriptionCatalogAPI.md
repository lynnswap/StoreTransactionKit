# Subscription catalog API design

Status: Proposed for the next beta API. The README shows this design, but the
source implementation and symbol documentation do not provide it yet.

## Purpose

StoreTransactionKit needs to translate StoreKit Product IDs into the app's
feature-access vocabulary without making Product IDs themselves the public
entitlement type. The translation must represent App Store Connect
subscription groups accurately, reject configuration drift, and preserve the
difference between unavailable entitlement state and a resolved empty set.

The primary consumer is an app with one auto-renewable subscription group that
contains multiple access levels and multiple durations at each level. A second
supported consumer has multiple independent subscription groups whose products
map into one app entitlement type.

## Goals

- Scope each Product ID type to one App Store Connect subscription group.
- Map multiple billing durations at the same access level to one app
  entitlement.
- Keep StoreKit's subscription group level and duration metadata in StoreKit.
- Validate the remote transaction metadata that the app's static catalog can
  know about without loading products eagerly.
- Publish raw and typed entitlement state as one atomic snapshot.
- Keep the surrounding app UI usable while entitlement state is unavailable.
- Support one group in the common case and explicit composition for independent
  groups.

## Non-goals

- The catalog does not describe consumables, non-consumables, or non-renewing
  subscriptions.
- The catalog does not own product merchandising, prices, localized names,
  purchase UI, renewal UI, or `Product.SubscriptionInfo.Status`.
- The framework does not infer app access from StoreKit `groupLevel`.
- The framework does not infer an entitlement for an unknown product.
- The design does not retain the current Product-ID-as-entitlement API for
  source compatibility. The package is still beta.

## StoreKit model

An App Store Connect subscription group contains auto-renewable subscriptions
with different access levels and durations. A customer can hold one
subscription product in a group at a time. Products at one level may have
monthly and yearly variants.

StoreKit owns these facts:

- `Product.SubscriptionInfo.subscriptionGroupID` identifies the group.
- `Product.SubscriptionInfo.groupLevel` ranks upgrade and downgrade paths;
  level `1` is the highest service level.
- `Product.SubscriptionInfo.subscriptionPeriod` describes the renewal period.
- `Transaction.currentEntitlements` includes current non-consumables,
  qualifying auto-renewable subscriptions, and non-renewing subscriptions. It
  excludes consumables.

The app owns the meaning of access. `SubscriptionEntitlement.tier1` is an app
domain value; it is not a copy of StoreKit `groupLevel == 1`. The explicit
Product ID mapping is the boundary between the two models.

## Consumer story

```swift
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

let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog,
    handleTransaction: handleTransaction,
    reportFailure: reportFailure
)

let canExportPDF = store.isEntitled(to: .tier1)
```

An app with independent groups composes them without erasing their nested
Product ID types:

```swift
let subscriptionCatalog = SubscriptionCatalog(Plans.self)
    .including(ChannelSubscriptions.self)
```

## Proposed public interface

```swift
public struct SubscriptionGroupID:
    RawRepresentable,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(rawValue: String)
}

public protocol SubscriptionGroup<Entitlement> {
    associatedtype Entitlement: Hashable & Sendable
    associatedtype ProductID:
        RawRepresentable<String> & CaseIterable

    static var id: SubscriptionGroupID { get }

    static func entitlement(
        for productID: ProductID
    ) -> Entitlement
}

public struct SubscriptionCatalog<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    public init<Group>(_ groupType: Group.Type)
    where Group: SubscriptionGroup<Entitlement>

    public func including<Group>(
        _ groupType: Group.Type
    ) -> SubscriptionCatalog<Entitlement>
    where Group: SubscriptionGroup<Entitlement>
}

public enum SubscriptionCatalogError: LocalizedError, Sendable {
    case unknownProduct(
        productID: String,
        subscriptionGroupID: SubscriptionGroupID
    )
    case productTypeMismatch(
        productID: String,
        actual: Product.ProductType
    )
    case subscriptionGroupMismatch(
        productID: String,
        expected: SubscriptionGroupID,
        actual: String?
    )

    public var errorDescription: String? { get }
}

public enum EntitlementStatus: Sendable {
    case loading
    case failed(any Error)
    case ready
}

@MainActor
@Observable
public final class TransactionStore<Entitlement>
where Entitlement: Hashable & Sendable {
    public var entitlementStatus: EntitlementStatus { get }
    public var entitlements: StoreEntitlements? { get }
    public var activeEntitlements: Set<Entitlement>? { get }

    public func isEntitled(to entitlement: Entitlement) -> Bool

    public init(
        subscriptionCatalog: SubscriptionCatalog<Entitlement>,
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    )

    public func process(
        _ result: Product.PurchaseResult
    ) async throws -> StorePurchaseOutcome

    @discardableResult
    public func refreshEntitlements() async throws -> StoreEntitlements

    public func history(
        for productID: Product.ID
    ) async throws -> [StoreTransactionSnapshot]

    @discardableResult
    public func restorePurchases() async throws -> StoreEntitlements

    public func close() async throws
}
```

`SubscriptionGroup` is a client-conformance protocol because each app supplies
its own closed group definition. Its requirements remain intentionally small.
The protocol itself is not `Sendable`, and `ProductID` does not require
`Hashable` or `Sendable`: the catalog consumes `allCases` synchronously and
normalizes each case to its raw `String` during construction. No group instance,
group metatype, or typed Product ID is retained.

Adding a protocol requirement after 1.0 would break client conformances. Future
optional metadata belongs in catalog initializers or configuration values, not
in a new `SubscriptionGroup` requirement.

`SubscriptionCatalog` is an immutable value. `including(_:)` returns another
catalog and leaves the receiver unchanged. This keeps the one-group use case to
one line while supporting the StoreKit case where independent subscriptions
must live in separate groups.

## Type-safety boundary

The API provides compile-time safety for app-owned declarations:

- `Plans.ProductID` cannot be passed where another group's nested Product ID is
  expected.
- The exhaustive `switch` in `entitlement(for:)` maps every declared Product ID.
- `SubscriptionGroupID` prevents a group identifier from being confused with an
  arbitrary Product ID at API boundaries.
- `TransactionStore` exposes the app's `Entitlement`, not raw Product IDs, to
  feature-gating code.
- `isEntitled(to:)` expresses a feature gate without exposing optional-set
  mechanics at each call site.

The compiler cannot validate App Store Connect. Runtime validation is therefore
part of the catalog contract rather than a substitute source of truth.

`SubscriptionGroupID.init(rawValue:)` preconditions that the raw value is not
empty. The identifier type owns that invariant because the value is also useful
outside the catalog, such as when passing `Plans.id.rawValue` to StoreKit UI.

## Catalog construction

Construction converts each group into normalized internal entries keyed by raw
Product ID. It also records the set of managed subscription group IDs.

The following remaining source-defined configuration errors fail with a
`precondition` during catalog construction:

- A group whose `ProductID.allCases` is empty.
- An empty Product ID raw value.
- A duplicate raw Product ID within one group or across included groups.
- A duplicate subscription group ID.

These are programmer errors in static app configuration. A nonthrowing
initializer keeps the normal composition root free of `try!`; the behavior is
analogous to `Dictionary(uniqueKeysWithValues:)` rejecting duplicate keys.
Duplicate checks remain necessary because a manually implemented
`RawRepresentable` or `CaseIterable` can violate the guarantees normally
provided by a raw-value enum.

Duplicate entitlement values are valid. Monthly and yearly products at one
access level are expected to produce the same entitlement, and independent
groups may grant the same app entitlement.

`SubscriptionCatalogError.errorDescription` includes the Product ID and the
expected and actual metadata needed to diagnose App Store Connect drift. These
descriptions are developer diagnostics and are not end-user presentation copy.
The public cases remain distinct so diagnostics and contract tests can identify
whether the shipped catalog is missing a product, names the wrong product type,
or assigns a product to the wrong group.

Catalog construction performs no network request and does not load `Product`
values. Product metadata is validated only when StoreKit supplies a verified
transaction snapshot.

## Runtime projection and validation

For each verified transaction in a candidate `StoreEntitlements` snapshot, the
catalog applies these rules before anything is published:

1. A transaction with `isUpgraded == true` remains in raw `entitlements` and is
   excluded from typed projection. It no longer grants access, so it does not
   require a current catalog entry.
2. A declared Product ID must have `productType == .autoRenewable`.
3. A declared Product ID must have the subscription group ID declared by its
   `SubscriptionGroup`.
4. An undeclared Product ID whose transaction belongs to a managed group fails
   with `SubscriptionCatalogError.unknownProduct` because the framework cannot
   infer its app entitlement.
5. An undeclared product outside every managed group remains in raw
   `entitlements` and is ignored by the typed projection.
6. Successful mappings are collected into a `Set`, so multiple durations and
   multiple groups may produce one typed entitlement value.

The upgrade filter runs before catalog lookup, so an upgraded historical
transaction alone does not require its retired Product ID to remain in the
catalog. The ID must remain while any supported customer can still hold that
product as a non-upgraded current entitlement. Every non-upgraded known or
managed-group transaction is validated before publication.

The catalog is a closed definition of every group it manages. Adding a Product
ID in App Store Connect can therefore make an older app binary report
`unknownProduct` after a user moves to that product. Product rollout must account
for supported older app versions; silently guessing a tier would risk granting
the wrong access.

Composition is atomic, not failure-isolated. If one included group has a catalog
mismatch, the typed projection for every included group becomes unavailable.
Per-group availability would require a different public state model and is not
provided by this API.

## Atomic publication owner

Raw and typed entitlement values describe one StoreKit query and must commit
together. Catalog projection and validation therefore run inside the entitlement
refresh coordination boundary, after unfinished transactions have been handled
and before any of the following occur:

- Updating the coordinator's current snapshot.
- Notifying the observable store.
- Completing a refresh receipt successfully.
- Returning a `StoreEntitlements` result to a caller.

If a query or transaction handler fails before producing a verified candidate,
the previous complete snapshot remains current. A catalog failure is different:
the verified candidate contradicts the old typed projection. The coordinator
clears its complete publication, the observable store becomes `.failed`, and
both public projections become `nil`. Keeping the old typed set could continue
granting a higher tier after a user has moved to an unknown lower-tier product.

The coordinator reports every physical query batch to the observable state
owner exactly once, before completing attached receipts:

```swift
private struct EntitlementPublication<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    let entitlements: StoreEntitlements
    let activeEntitlements: Set<Entitlement>
}

private enum EntitlementRefreshOutcome<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    case success(EntitlementPublication<Entitlement>)
    case transientFailure(any Error)
    case catalogFailure(SubscriptionCatalogError)
}

didComplete(
    token: UInt64,
    outcome: EntitlementRefreshOutcome<Entitlement>
)
```

For a coalesced batch, `didComplete.token` is the last reservation token in that
batch. The coordinator delivers completions in physical token order. A single
`TransactionStore` reducer owns all availability transitions; startup, direct,
and background callers never write observable state themselves.

`transientFailure` carries the normalized underlying error that belongs in
`entitlementStatus`. Any internal reporting-owner wrapper remains available to
receipts and reporting authority but does not leak into observable state.
Diagnostic reporting is a separate ownership decision, so `didComplete` does
not call `reportFailure`.

Mapping in `TransactionStore.activeEntitlements` after raw publication would
violate atomicity and is not part of the design.

## Observable state

The three public properties are separate views of one private state value:

```swift
private enum EntitlementAvailability<Entitlement> {
    case loading
    case failed(any Error)
    case ready(
        entitlements: StoreEntitlements,
        activeEntitlements: Set<Entitlement>
    )
}
```

`entitlementStatus`, `entitlements`, and `activeEntitlements` are computed from
that value. The store never updates three independent stored properties. This
prevents Observation from rendering combinations such as `.ready` with a `nil`
typed set.

The public meaning is:

| Status | `entitlements` | `activeEntitlements` | Meaning |
| --- | --- | --- | --- |
| `.loading` | `nil` | `nil` | No readiness attempt has completed. |
| `.failed(error)` | `nil` | `nil` | No usable complete snapshot exists; inspect `error` for the reason. |
| `.ready` | non-`nil` | non-`nil` | A complete raw and typed snapshot is available. Empty values mean no entitlement. |

`.loading` is only the initial state. The store does not return to it for later
refreshes. `.failed` means that no usable snapshot exists; it does not mean that
the most recent operation failed.

State transitions are:

| Event | Result |
| --- | --- |
| Initialization | `.loading` with both projections `nil`. |
| Any successful candidate | `.ready` with the new atomic snapshot. |
| Query or handler failure while `.loading` or `.failed` | `.failed(error)` with both projections `nil`. |
| Query or handler failure after `.ready` | Preserve the previous `.ready` snapshot. This includes a late startup failure after another refresh has already succeeded. |
| Catalog failure in a verified candidate | `.failed(error)` with both projections `nil`, even after `.ready`; stale typed access is invalidated. |
| Successful empty query | `.ready`; both collections are empty, not `nil`. |
| Unverified current-entitlement element | Omit and report that element; publish the verified remainder if the query otherwise succeeds. |
| Close | Preserve the last entitlement state; lifecycle errors are reported by operations, not by `EntitlementStatus`. |

The current `startupError` property is removed. Its readiness role moves to
`entitlementStatus`, while operational diagnostics continue through thrown
errors and `reportFailure`.

SwiftUI calls `isEntitled(to:)` directly. It does not copy the set or status into
`@State`, and normal app content does not wait for readiness. The method returns
`true` only when the current ready snapshot contains the requested entitlement;
it returns `false` while loading, after a readiness failure, and when a ready set
does not contain the value. Code that needs to distinguish those reasons reads
`entitlementStatus`. `activeEntitlements` remains available for consumers that
need the complete typed set.

This is exact set membership. It does not infer that StoreKit group level 1
contains level 2, or that one app entitlement includes another. If multiple plan
identities grant one feature, the app expresses that policy by checking each
accepted entitlement. The catalog continues to own only Product ID to app-value
translation.

## Failure routing

Failure delivery depends on ownership of the operation, not only on the error
type:

| Failure | Observable state | Direct caller | Background diagnostics |
| --- | --- | --- | --- |
| Invalid source-defined catalog | Store is not created | None | `precondition` failure |
| Startup query or handler failure | Become `.failed` if no snapshot exists; otherwise preserve `.ready` | No startup caller | Report once when no other physical-work owner already reports it |
| Startup catalog failure | `.failed(error)` and invalidate any previous projection | No startup caller | Report once when no other physical-work owner already reports it |
| Explicit query or handler failure | Become or remain `.failed` without a snapshot; otherwise preserve `.ready` | Throw underlying error | Do not duplicate while a caller owns it |
| Explicit catalog failure | `.failed(error)` and invalidate any previous projection | Throw underlying error | Do not duplicate while a caller owns it |
| Background query or handler failure after `.ready` | Preserve `.ready` snapshot | None | Report once through `reportFailure` |
| Background catalog failure | `.failed(error)` and invalidate any previous projection | None | Report once through `reportFailure` |
| Current-entitlement verification failure for one element | Publish verified remainder | Attached operation may still succeed | Report omitted element once |

A catalog projection error participates in the same physical-work ownership and
coalescing rules as a StoreKit query error, but its observable-state transition
is intentionally fail-closed. Background-owned catalog failures use
`StoreTransactionBackgroundFailure.Source.entitlementRefresh` with the public
`SubscriptionCatalogError` as `underlyingError`.

Reservation role alone does not decide whether to report. Every startup,
background, and direct reservation in one physical batch shares one reporting
authority. Direct participation is registered as part of `reserve`, before the
worker can start, so a fast failure cannot race a later observer binding.

The authority collects one background report candidate and all direct-caller
dispositions, then decides once:

- If any attached direct caller receives the error, no background diagnostic is
  sent.
- If every direct caller abandons the work, one background diagnostic is sent.
- If no direct caller participated, the startup or background physical work
  sends one diagnostic.

This is independent of whether background or direct work reserved first. State
completion still occurs exactly once through `didComplete`.

## Product-type boundaries

`SubscriptionCatalog` is intentionally specific:

- Auto-renewable subscriptions are mapped by group and Product ID.
- Non-consumables may appear in raw `StoreEntitlements`, but this catalog does
  not map them to typed app access.
- Non-renewing subscriptions may appear in raw current entitlements even after
  their intended service period; app-owned expiry policy is outside this
  catalog.
- Consumables never appear in `Transaction.currentEntitlements`. They still pass
  through the durable `handleTransaction` path so the app can update its owned
  balance before the transaction is finished.

If a concrete consumer later needs typed non-consumable access, it requires a
separate design. It must not be represented as a member of
`SubscriptionGroup`, because StoreKit does not model it that way.

## Ownership map

| Responsibility | Owner |
| --- | --- |
| Group ID, Product ID cases, and Product ID to app-entitlement mapping | App-defined `SubscriptionGroup` conformance |
| Normalized lookup, managed-group membership, and catalog validation | `SubscriptionCatalog` |
| StoreKit query and unfinished-transaction reconciliation | `CurrentEntitlementReconciler` |
| Candidate projection, atomic publication, refresh coalescing, ordered completion, and receipt completion | Generic entitlement refresh coordinator |
| Observable availability reducer and process-lifetime facade | `TransactionStore` |
| Direct/background reporting authority and exactly-once diagnostic delivery | Runtime pipeline and failure reporter dispatcher |
| Durable business effect and idempotency across launches | App transaction handler |
| Product merchandising and subscription status presentation | App using StoreKit directly |

No UI type owns semantic entitlement state. No second mapping is performed in a
view, callback, or computed property outside the catalog owner.

## Lifecycle and concurrency

- `TransactionStore` remains `@MainActor`, `@Observable`, and process-owned.
- `SubscriptionCatalog` is immutable and `Sendable` after normalization. Its
  storage uses value semantics rather than shared mutable storage or
  `@unchecked Sendable`.
- App-defined `Entitlement` values cross concurrency boundaries and must be
  `Hashable & Sendable`.
- Group types and typed Product IDs are consumed synchronously during catalog
  construction and do not cross concurrency boundaries.
- The store starts monitoring during initialization and retains the catalog for
  every entitlement projection.
- Existing transaction handler, failure reporter, reentrancy, and `close()`
  contracts remain unchanged except for the readiness reporting described
  above.

## Required contract tests

### Catalog tests

- Every declared monthly and yearly Product ID maps to its expected entitlement.
- Multiple groups compose into one catalog without type erasure at the call site.
- `including(_:)` does not change the original catalog or share mutable storage.
- An empty `SubscriptionGroupID` fails when the ID value is constructed.
- Empty Product IDs, empty groups, duplicate group IDs, and duplicate Product
  IDs fail during catalog construction.
- Duplicate entitlement values remain valid.
- Each `SubscriptionCatalogError.errorDescription` identifies the Product ID and
  relevant expected or actual metadata.
- Known Product ID with a wrong product type fails projection.
- Known Product ID with a wrong or missing group ID fails projection.
- Unknown Product ID inside a managed group fails projection.
- Unknown Product ID outside managed groups remains raw and is ignored by the
  typed set.
- A catalog mismatch in one included group fails the complete composed
  projection.
- Known and unknown upgraded transactions remain raw, do not require a current
  catalog entry, and do not grant typed access.

### State-owner tests

- Initial state is `.loading` with both projections `nil`.
- A successful empty query produces `.ready` and two empty collections.
- Startup query, handler, and catalog failures produce `.failed` without a
  partial candidate snapshot when no earlier query has succeeded.
- A later success recovers `.failed` to `.ready` atomically.
- A late startup query failure after a background success preserves `.ready`.
- Explicit and background query or handler failures after `.ready` preserve the
  previous raw and typed snapshot.
- A verified known-tier to unknown-tier change produces `.failed`, clears both
  public projections, and makes `isEntitled(to:)` return `false`.
- A coalesced catalog failure does not publish a partial raw or typed snapshot.
- Observation never publishes a status/projection combination outside the state
  table.
- `withObservationTracking` observes `isEntitled(to:)` through the private
  availability value.
- `isEntitled(to:)` returns `false` for `.loading`, `.failed`, and a ready set
  without the value, and `true` only for a matching ready entitlement.

### Coordination and reporting tests

- Physical query completions reach the availability reducer once and in token
  order before attached receipts complete. A coalesced completion uses the last
  reservation token.
- Startup-owned plain query failure is reported once.
- Startup-owned catalog failure is reported once.
- Background-owner/direct-observer and direct-owner/background-observer catalog
  failures each complete state once, deliver the error to the attached direct
  caller, and send no background diagnostic.
- Background-owner/startup-observer and startup-owner/background-observer
  failures each complete state and diagnostics once.
- A physical failure is reported once if every direct caller abandons it.

### Integration and distribution tests

- App-hosted StoreKit tests cover monthly/yearly mapping, upgrades, a known-tier
  to unknown-tier transition, restore, revocation, and recovery without fixed
  sleeps.
- The external consumer fixture builds the README story using only public API.
- Swift 6 strict-concurrency builds prove the primary-associated-type and
  `Sendable` surface.
- DocC builds without warnings after symbol documentation is added.

## Implementation transaction

This public redesign is complete only when one change updates all of the
following:

- Public source and symbol documentation.
- Unit and app-hosted StoreKit tests.
- The external consumer fixture.
- README and DocC examples.
- Any dependent app and its resolved package revision.

No compatibility alias or deprecated initializer is planned while the package
is beta.

## References

- [Offer auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
- [`Product.SubscriptionInfo.subscriptionGroupID`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/subscriptiongroupid)
- [`Product.SubscriptionInfo.groupLevel`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/grouplevel)
- [`Product.SubscriptionInfo.subscriptionPeriod`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/subscriptionperiod)
- [`Transaction.isUpgraded`](https://developer.apple.com/documentation/storekit/transaction/isupgraded)
- [`Transaction.currentEntitlements`](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
