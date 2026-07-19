# Auto-renewable subscription catalog, delegate, override, and testing API design

Status: Proposed for the next beta API. The README shows this design, but the
source implementation and symbol documentation do not provide it yet.

## Purpose

StoreTransactionKit needs to translate StoreKit Product IDs into the app's
feature-access vocabulary without making Product IDs themselves the public
entitlement type. The translation must represent App Store Connect
subscription groups accurately, reject configuration drift, and preserve the
difference between unavailable entitlement state and a resolved empty set.

The same typed entitlement model must also support an app-selected StoreKit
bypass and deterministic app or ViewModel tests. Those paths must not invent
StoreKit transactions or fork production entitlement semantics.

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
- Finish automatically only when a transaction is a validated auto-renewable
  subscription managed by the catalog; require an app decision for every other
  product.
- Separate the finish decision from optional background-failure notification.
- Let the app construct a fixed entitlement override without environment
  detection inside the framework.
- Let tests drive the real transaction and entitlement pipeline without a
  `.storekit` configuration or timing guesses.
- Separate virtual time control from causal operation completion.

## Non-goals

- The catalog does not describe consumables, non-consumables, or non-renewing
  subscriptions.
- The catalog does not own product merchandising, prices, localized names,
  purchase UI, renewal UI, or `Product.SubscriptionInfo.Status`.
- The framework does not infer app access from StoreKit `groupLevel`.
- The framework does not infer an entitlement for an unknown product.
- The framework does not detect TestFlight, previews, debug builds, receipts,
  or other distribution environments to select override mode.
- The no-configuration test harness does not validate StoreKit verification,
  JWS, App Store Connect metadata, system purchase UI, or StoreKit renewal
  scheduling.
- Advancing a test clock does not mean that the transaction pipeline is idle or
  that an entitlement update has been published.
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

let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog
)

let canExportPDF = store.isEntitled(to: .tier1)
```

The app can use the same catalog and entitlement type for a fixed StoreKit
bypass:

```swift
let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog,
    overridingEntitlements: [
        SubscriptionEntitlement.tier1,
        .tier2,
    ]
)
```

The app owns the condition that selects this initializer. Passing an empty
sequence explicitly selects override mode with no active entitlement.

An app with independent groups composes them without erasing their nested
Product ID types:

```swift
let subscriptionCatalog = AutoRenewableSubscriptionCatalog(Plans.self)
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

public protocol AutoRenewableSubscriptionGroup<Entitlement> {
    associatedtype Entitlement: Hashable & Sendable
    associatedtype ProductID:
        RawRepresentable<String> & CaseIterable

    static var id: SubscriptionGroupID { get }

    static func entitlement(
        for productID: ProductID
    ) -> Entitlement
}

public struct AutoRenewableSubscriptionCatalog<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    public init<Group>(_ groupType: Group.Type)
    where Group: AutoRenewableSubscriptionGroup<Entitlement>

    public func including<Group>(
        _ groupType: Group.Type
    ) -> Self
    where Group: AutoRenewableSubscriptionGroup<Entitlement>
}

public enum AutoRenewableSubscriptionCatalogError: LocalizedError, Sendable {
    case unknownProduct(
        productID: Product.ID,
        subscriptionGroupID: SubscriptionGroupID
    )
    case productTypeMismatch(
        productID: Product.ID,
        actual: Product.ProductType
    )
    case subscriptionGroupMismatch(
        productID: Product.ID,
        expected: SubscriptionGroupID,
        actual: String?
    )

    public var errorDescription: String? { get }
}

public enum EntitlementStatus: Sendable {
    case loading
    case failed(any Error)
    case ready
    case overridden
}

public enum StoreTransactionOperation: Sendable, Hashable {
    case processPurchase
    case currentEntitlements
    case history
    case restorePurchases
    case close
}

public enum StoreTransactionError: Error, Sendable, Hashable {
    case closing
    case closed
    case unknownPurchaseResult
    case unhandledTransaction(
        productID: Product.ID,
        productType: Product.ProductType
    )
    case reentrantOperation(operation: StoreTransactionOperation)
    case operationUnavailableInOverride(operation: StoreTransactionOperation)
}

public enum StoreTransactionHandlingPolicy: Sendable, Hashable {
    case automatic
    case finish
    case keepUnfinished
}

public protocol TransactionStoreDelegate: AnyObject, Sendable {
    func transactionStore(
        decidePolicyFor transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy

    func transactionStore(
        didFailWith failure: StoreTransactionBackgroundFailure
    ) async
}

public extension TransactionStoreDelegate {
    func transactionStore(
        decidePolicyFor transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        .automatic
    }

    func transactionStore(
        didFailWith failure: StoreTransactionBackgroundFailure
    ) async {}
}

public enum StorePurchaseOutcome: Sendable, Hashable {
    case completed(StoreTransactionSnapshot)
    case keptUnfinished(StoreTransactionSnapshot)
    case pending
    case userCancelled
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
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)? = nil
    )

    public init(
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        overridingEntitlements: some Sequence<Entitlement>
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

## Optional transaction delegate

Omitting `delegate` uses `.automatic` handling and performs no app-specific
failure notification. The store strongly retains a supplied delegate until
`close()` finishes or the store is deinitialized.

`TransactionStoreDelegate` follows the decision/notification split used by
`WKNavigationDelegate`: a method that grants permission for a consequential
operation returns a policy, while a method that reports an event that has
already occurred returns no policy. The transaction method is also `throws`
because failing to reach a decision is different from deliberately choosing a
normal policy.

Both methods have default implementations. A delegate interested only in
background diagnostics implements `transactionStore(didFailWith:)` and inherits
`.automatic` transaction handling. A delegate interested only in transaction
policy implements the decision method and inherits the no-op notification.

Before applying a policy, the catalog classifies each verified transaction:

- A **managed** transaction has a declared Product ID, `productType ==
  .autoRenewable`, and the declared subscription group ID. A superseded
  transaction with `isUpgraded == true`, `.autoRenewable` type, and a managed
  group is also managed for finishing even when its retired Product ID is no
  longer declared; it cannot grant typed access. A Product ID that is still
  declared must match its declaration in either case.
- An **invalid** transaction uses a declared Product ID with the wrong type or
  group, or an undeclared non-upgraded Product ID inside a managed group. It
  fails with `AutoRenewableSubscriptionCatalogError` before the delegate is
  called and is never finished.
- An **unmanaged** transaction belongs outside the catalog: a consumable,
  non-consumable, non-renewing subscription, or an auto-renewable subscription
  in another group.

The decision method is called for managed and unmanaged transactions. Its
policies mean:

- `.automatic` is the safe default. It finishes a managed transaction and
  throws `StoreTransactionError.unhandledTransaction` for an unmanaged one. It
  is not an alias for unconditional `.finish`.
- `.finish` means the app has durably applied this business event, or has
  established from its idempotency ledger that the event was already applied.
  StoreTransactionKit then calls `finish()`, records the exact transaction
  revision as completed, refreshes current entitlements, and publishes the
  resulting state.
- `.keepUnfinished` means the app reached an expected deferral decision and,
  when its own model requires it, recorded that decision durably. It is not a
  substitute for catching a processing error. StoreTransactionKit does not call
  `finish()` or send a failure notification, but it continues the causal
  entitlement refresh. A direct purchase returns
  `.keptUnfinished(transaction)` after that refresh and MainActor publication
  complete.
- Throwing means that the delegate could not establish either a durable
  `.finish` decision or a valid `.keepUnfinished` decision. StoreTransactionKit
  does not call `finish()`. A direct operation forwards the error to its caller;
  background-owned work sends it to `transactionStore(didFailWith:)`. A later
  independent attempt can redeliver the transaction.

This keeps subscription-only apps concise without allowing the default path to
finish a consumable or another product that has no handling owner. An app that
also sells such products implements the decision method, persists the product's
business effect, and returns `.finish`. An app that only wants diagnostics can
implement the notification method alone; an unmanaged background transaction
then arrives there as an `unhandledTransaction` failure.

The transaction-processing coordinator owns one causal decision receipt for an
exact revision from admission through completion of the refresh caused by that
decision. Direct results, `Transaction.updates`, and
`Transaction.unfinished` reconciliation all attach to that receipt instead of
invoking the delegate again. Coalesced reservations share the same receipt, and
the reconciler seeds its exact-revision exclusion set from every receipt in the
physical refresh. The receipt completes only after the refresh succeeds or
fails and all attached callers and reporting owners receive that result.

`.keepUnfinished` is not added to the bounded completed-revision cache or the
failed-attempt set. The causal receipt is discarded when its physical refresh
completes, after which a non-coalesced update, status change, explicit refresh,
restore, or startup attempt may present the exact revision again.
StoreTransactionKit does not schedule a timer or backoff retry. Coalescing uses
exact revision identity rather than transaction ID, so a later revocation or
another revised business event is not suppressed. Any app-owned effect performed
before returning a policy must remain idempotent.

Completed revisions enter a bounded process-local cache. The cache prevents
nearby duplicate delivery from repeating policy work, but it is not a durable
business ledger and does not promise process-lifetime retention. Eviction may
allow an exact revision to be presented again, so an app delegate's durable
effect remains idempotent.

`transactionStore(didFailWith:)` is an optional observation hook with a default
no-op implementation. It cannot change a transaction decision, request a retry,
or suppress a thrown error. Admitted notifications are delivered serially with
backpressure, and `close()` waits for each invocation to return. Direct errors
that reach an attached caller are not duplicated as background notifications.

A weak app delegate would allow its policy and diagnostic receiver to disappear
after initialization. The store therefore retains its delegate strongly, and a
delegate that keeps a reference back to the store must make that reference weak.
The delegate must not start an admission-bearing operation on the same store —
`process(_:)`, `refreshEntitlements()`, `history(for:)`, `restorePurchases()`, or
`close()` — directly or through an awaited child or detached task. Read-only
entitlement inspection does not enter the transaction coordinator and is not a
`reentrantOperation`. The methods omit a store parameter because policy normally
depends on the supplied transaction, not on the store's generic entitlement
type.

The protocol is class-bound and `Sendable`, but it is not actor-bound. A
delegate that owns mutable state directly can be an actor. A checked-Sendable
`final class` with immutable `Sendable` dependencies is equally valid. Runtime
delivery ordering does not make an otherwise unsynchronized mutable class safe.

`StoreTransactionOperation` is the existing closed diagnostic vocabulary rather
than a free-form string. The new error case reuses it so an override-mode
failure identifies the rejected operation without parsing text.

`AutoRenewableSubscriptionGroup` is a client-conformance protocol because each
app supplies its own closed group definition. Its requirements remain
intentionally small. The protocol itself is not `Sendable`, and `ProductID` does
not require `Hashable` or `Sendable`: the catalog consumes `allCases`
synchronously and normalizes each case to its raw `String` during construction.
No group instance, group metatype, or typed Product ID is retained.

Adding a protocol requirement after 1.0 would break client conformances. Future
optional metadata belongs in catalog initializers or configuration values, not
in a new `AutoRenewableSubscriptionGroup` requirement.

`AutoRenewableSubscriptionCatalog` is an immutable value. `including(_:)`
returns another catalog and leaves the receiver unchanged. This keeps the
one-group use case to one line while supporting the StoreKit case where
independent subscriptions must live in separate groups.

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

The identifier remains `SubscriptionGroupID`, rather than
`AutoRenewableSubscriptionGroupID`, because it mirrors StoreKit's
`subscriptionGroupID` vocabulary and StoreKit subscription groups already imply
auto-renewable subscriptions. The longer qualifier belongs on the app-defined
group protocol and catalog, where it distinguishes their product scope.
Initializer labels remain `subscriptionCatalog:` because the argument's static
type already carries the `AutoRenewable` qualifier.

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

`AutoRenewableSubscriptionCatalogError.errorDescription` includes the Product
ID and the expected and actual metadata needed to diagnose App Store Connect
drift. These descriptions are developer diagnostics and are not end-user
presentation copy. The public cases remain distinct so diagnostics and contract
tests can identify whether the shipped catalog is missing a product, names the
wrong product type, or assigns a product to the wrong group.

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
   `AutoRenewableSubscriptionGroup`.
4. An undeclared Product ID whose transaction belongs to a managed group fails
   with `AutoRenewableSubscriptionCatalogError.unknownProduct` because the
   framework cannot infer its app entitlement.
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

## Fixed entitlement override

`overridingEntitlements` is a composition-root choice, not mutable runtime
state. The initializer consumes `some Sequence<Entitlement>`, normalizes it once
to a `Set`, and publishes `.overridden` immediately. An array literal is the
common spelling; an existing `Set` or another finite sequence is equally valid.

An empty sequence means “override with no active entitlement.” It is observably
different from selecting the live initializer, which begins in `.loading`.
There is no Boolean “unlock everything” form because the framework does not
know the app's complete entitlement universe or inclusion policy.

An override store has these contracts:

- It does not create a StoreKit source, start update or status monitors, query
  current entitlements, process transactions, retain a delegate, or invoke
  delegate methods.
- `activeEntitlements` is the normalized override set and
  `isEntitled(to:)` performs exact membership against it.
- `entitlements` is `nil`. The framework does not synthesize raw transactions
  to make the override look like a verified StoreKit snapshot.
- `process(_:)`, `refreshEntitlements()`, `history(for:)`, and
  `restorePurchases()` throw
  `StoreTransactionError.operationUnavailableInOverride(operation:)` before
  starting any work.
- `close()` is successful and idempotent even though no runtime work exists.

The override initializer does not accept a delegate; accepting one that can
never receive a decision or notification would create a false contract. The app
owns whether a preview, internal build, TestFlight build, UI test, or another
environment uses this initializer. StoreTransactionKit does not inspect the
receipt or build configuration to make that decision.

The catalog remains part of the initializer so the override uses the same
`Entitlement` domain as the live store and the app has one composition shape.
No Product ID is reverse-mapped from an entitlement: monthly and yearly
products may intentionally grant the same value, so such a reverse mapping is
not well-defined.

## Atomic publication owner

Raw and typed entitlement values describe one StoreKit query and must commit
together. Catalog projection and validation therefore run inside the entitlement
refresh coordination boundary, after unfinished transactions have been handled
and before any of the following occur:

- Updating the coordinator's current snapshot.
- Notifying the observable store.
- Completing a refresh receipt successfully.
- Returning a `StoreEntitlements` result to a caller.

If a query or non-catalog transaction-handling error occurs before producing a
verified candidate, the previous complete snapshot remains current. A catalog
failure is different: the verified candidate contradicts the old typed
projection. The coordinator clears its complete publication, the observable
store becomes `.failed`, and both public projections become `nil`. Keeping the
old typed set could continue granting a higher tier after a user has moved to an
unknown lower-tier product.

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
    case catalogFailure(AutoRenewableSubscriptionCatalogError)
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
not call `transactionStore(didFailWith:)`.

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
    case overridden(activeEntitlements: Set<Entitlement>)
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
| `.overridden` | `nil` | non-`nil` | StoreKit is bypassed and the app-supplied typed set is authoritative. An empty set means no entitlement. |

`.loading` is only the initial state of a live store. The store does not return
to it for later refreshes. `.failed` means that no usable live snapshot exists;
it does not mean that the most recent operation failed. `.overridden` is the
only state of an override store.

State transitions are:

| Event | Result |
| --- | --- |
| Live initialization | `.loading` with both projections `nil`. |
| Override initialization | `.overridden` with raw `entitlements == nil` and the normalized typed set. |
| Any successful candidate | `.ready` with the new atomic snapshot. |
| Query or non-catalog transaction-handling error while `.loading` or `.failed` | `.failed(error)` with both projections `nil`. |
| Query or non-catalog transaction-handling error after `.ready` | Preserve the previous `.ready` snapshot. This includes a late startup failure after another refresh has already succeeded. |
| Catalog failure in a verified candidate | `.failed(error)` with both projections `nil`, even after `.ready`; stale typed access is invalidated. |
| Successful empty query | `.ready`; both collections are empty, not `nil`. |
| Unverified current-entitlement element | Omit and report that element; publish the verified remainder if the query otherwise succeeds. |
| Close | Preserve the last entitlement state; lifecycle errors are reported by operations, not by `EntitlementStatus`. Closing an override is an idempotent success. |

The current `startupError` property is removed. Its readiness role moves to
`entitlementStatus`, while operational diagnostics continue through thrown
errors and `transactionStore(didFailWith:)`.

SwiftUI calls `isEntitled(to:)` directly. It does not copy the set or status into
`@State`, and normal app content does not wait for readiness. The method returns
`true` when a ready or overridden set contains the requested entitlement. It
returns `false` while loading, after a readiness failure, and when the available
set does not contain the value. Code that needs to distinguish those reasons or
identify the source reads `entitlementStatus`. `activeEntitlements` remains
available for consumers that need the complete typed set.

This is exact set membership. It does not infer that StoreKit group level 1
contains level 2, or that one app entitlement includes another. If multiple plan
identities grant one feature, the app expresses that policy by checking each
accepted entitlement. The catalog continues to own only Product ID to app-value
translation.

## Failure routing

Failure delivery depends on ownership of the operation, not only on the error
type:

| Failure | Observable state | Direct caller | Background notification |
| --- | --- | --- | --- |
| Invalid source-defined catalog | Store is not created | None | `precondition` failure |
| StoreKit operation requested from an override store | Preserve `.overridden` | Throw `operationUnavailableInOverride(operation:)` | None |
| Startup query or non-catalog transaction-handling error | Become `.failed` if no snapshot exists; otherwise preserve `.ready` | No startup caller | Notify once when no other physical-work owner already reports it |
| Startup catalog failure | `.failed(error)` and invalidate any previous projection | No startup caller | Notify once when no other physical-work owner already reports it |
| Explicit query or non-catalog transaction-handling error | Become or remain `.failed` without a snapshot; otherwise preserve `.ready` | Throw underlying error | Do not duplicate while a caller owns it |
| Explicit catalog failure | `.failed(error)` and invalidate any previous projection | Throw underlying error | Do not duplicate while a caller owns it |
| Background query or non-catalog transaction-handling error after `.ready` | Preserve `.ready` snapshot | None | Notify once through `transactionStore(didFailWith:)` |
| Background catalog failure | `.failed(error)` and invalidate any previous projection | None | Notify once through `transactionStore(didFailWith:)` |
| Current-entitlement verification failure for one element | Publish verified remainder | Attached operation may still succeed | Notify once for the omitted element |

A catalog projection error participates in the same physical-work ownership and
coalescing rules as a StoreKit query error, but its observable-state transition
is intentionally fail-closed. Background-owned catalog failures use
`StoreTransactionBackgroundFailure.Source.entitlementRefresh` with the public
`AutoRenewableSubscriptionCatalogError` as `underlyingError`.

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

`AutoRenewableSubscriptionCatalog` is intentionally specific:

- Auto-renewable subscriptions are mapped by group and Product ID.
- Non-consumables may appear in raw `StoreEntitlements`, but this catalog does
  not map them to typed app access.
- Non-renewing subscriptions may appear in raw current entitlements even after
  their intended service period; app-owned expiry policy is outside this
  catalog.
- Consumables never appear in `Transaction.currentEntitlements`. They still pass
  through the transaction decision path. An app that owns a consumable balance
  supplies a delegate and returns `.finish` only after updating that balance
  durably.

`TransactionStore` remains the single process-wide transaction monitor and
finish authority across product types. The product-specific catalog changes
typed projection and automatic handling; it does not create a second StoreKit
listener. `.automatic` fails for every transaction outside this catalog, so an
app must provide the handling owner before it can finish one.

If a concrete consumer later needs typed non-consumable access, it requires a
separate design. It must not be represented as a member of
`AutoRenewableSubscriptionGroup`, because StoreKit does not model it that way.

## Ownership map

| Responsibility | Owner |
| --- | --- |
| Group ID, Product ID cases, and Product ID to app-entitlement mapping | App-defined `AutoRenewableSubscriptionGroup` conformance |
| Choosing whether a particular app composition bypasses StoreKit | App composition root |
| Normalized lookup, managed-group membership, and catalog validation | `AutoRenewableSubscriptionCatalog` |
| Normalizing and publishing a fixed override set | `TransactionStore` override initializer and availability reducer |
| StoreKit query and unfinished-transaction reconciliation | `CurrentEntitlementReconciler` |
| Exact-revision admission, causal decision receipts, and policy completion | Transaction processing coordinator |
| Candidate projection, atomic publication, refresh coalescing, ordered completion, and receipt completion | Generic entitlement refresh coordinator |
| Observable availability reducer and process-lifetime facade | `TransactionStore` |
| Direct/background reporting authority and exactly-once diagnostic delivery | Runtime pipeline and failure notification dispatcher |
| Default handling for validated auto-renewable transactions | `AutoRenewableSubscriptionCatalog` classification and `.automatic` policy |
| Optional durable business effect, idempotency, and handling policy | App `TransactionStoreDelegate` |
| Product merchandising and subscription status presentation | App using StoreKit directly |
| Synthetic source, command admission, action acknowledgement, and test lifecycle | `withTransactionStoreTestHarness` and its `TransactionStoreTestHarness` in `StoreTransactionKitTesting` |
| Time policy in app tests | The app component that performs the timed work, through an injected `Clock` |
| Virtual time and sleeper-registration barriers | `TransactionStoreTestClock` in `StoreTransactionKitTesting` |

No UI type owns semantic entitlement state. No second mapping is performed in a
view, delegate method, or computed property outside the catalog owner.

## Lifecycle and concurrency

- `TransactionStore` remains `@MainActor`, `@Observable`, and process-owned.
- `AutoRenewableSubscriptionCatalog` is immutable and `Sendable` after
  normalization. Its storage uses value semantics rather than shared mutable
  storage or `@unchecked Sendable`.
- App-defined `Entitlement` values cross concurrency boundaries and must be
  `Hashable & Sendable`.
- Group types and typed Product IDs are consumed synchronously during catalog
  construction and do not cross concurrency boundaries.
- A live store starts monitoring during initialization and retains the catalog
  for every entitlement projection.
- A live store strongly retains an app delegate when supplied. Without one, it
  uses `.automatic` and has no app-specific failure receiver. Transaction
  decisions are serialized. Failure notifications are also serialized, but
  decision and notification delivery are independent and may overlap.
- An override store starts no asynchronous task. Its normalized entitlement set
  is immutable for the store's lifetime, and `close()` is idempotent.
- `close()` stops new admission and waits for every admitted delegate decision
  and failure notification to return. A direct call, or a `Task {}` call, that
  inherits the delegate's callback context and starts an admission-bearing store
  operation fails with
  `reentrantOperation(operation:)`.
- `Task.detached` does not inherit task-local callback context, so the framework
  cannot identify that call as delegate-originated. Awaiting detached work that
  calls the same store is still unsupported because it can create the same
  dependency cycle. Actor isolation, `@isolated(any)`, `sending`,
  `SendableMetatype`, and `@_inheritActorContext` do not encode parent-task
  ancestry or make an instance method unavailable only to detached tasks.
- A process-wide “delegate callback is active” gate is not used to simulate that
  provenance. It would also reject unrelated UI or lifecycle operations that
  happen to overlap a suspended delegate callback.

## Deterministic consumer testing

The package adds a second public SwiftPM product with a one-way dependency:

```text
StoreTransactionKitTesting
        ↓
StoreTransactionKit
```

Production targets import only `StoreTransactionKit`. App test targets import
`StoreTransactionKitTesting`, which builds a real `TransactionStore` around a
package-scoped synthetic StoreKit source. The production module owns the
transaction pipeline, catalog projection, availability reducer, and public
store type; the testing module does not reimplement any of them.

The initial testing surface is:

```swift
public final class TransactionStoreTestClock: Clock, Sendable {
    public typealias Duration = Swift.Duration

    public struct Instant: InstantProtocol, Sendable {
        public typealias Duration = Swift.Duration

        public static let zero: Instant

        public func advanced(by duration: Duration) -> Instant
        public func duration(to other: Instant) -> Duration

        public static func < (lhs: Instant, rhs: Instant) -> Bool
    }

    public var now: Instant { get }
    public var minimumResolution: Duration { get }

    public init(now: Instant = .zero)

    public func sleep(
        until deadline: Instant,
        tolerance: Duration?
    ) async throws

    public func advance(by duration: Duration)

    public func waitUntilPendingSleepCount(
        reaches count: Int
    ) async throws
}

@MainActor
public final class TransactionStoreTestHarness<Entitlement>
where Entitlement: Hashable & Sendable {
    public let store: TransactionStore<Entitlement>
    public private(set) var reportedFailures:
        [StoreTransactionBackgroundFailure] { get }

    @discardableResult
    public func purchase<Group>(
        _ productID: Group.ProductID,
        in groupType: Group.Type
    ) async throws -> StorePurchaseOutcome
    where Group: AutoRenewableSubscriptionGroup<Entitlement>
}

@MainActor
public func withTransactionStoreTestHarness<Entitlement, Result>(
    subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
    delegate: (any TransactionStoreDelegate)? = nil,
    _ operation: @MainActor (
        TransactionStoreTestHarness<Entitlement>
    ) async throws -> Result
) async throws -> Result
where Entitlement: Hashable & Sendable
```

The harness does not accept a Clock. None of the production work it drives owns
a delay, deadline, retry interval, or other time policy, so injecting a Clock
there would be unused ceremony. When `delegate` is omitted, the common
no-subscription → purchase → entitled test uses `.automatic`, which resolves to
finish for the catalog-validated synthetic subscription, and relies on the
command's causal receipt. Supplying a delegate exercises an app's real durable
effect and policy decision.

`withTransactionStoreTestHarness` is the public construction and lifecycle
boundary. It initializes the harness, invokes `operation`, and drains and closes
framework-owned work before returning on success, failure, or cancellation. If
`operation` throws, its error is rethrown after cleanup. Harness construction
and mandatory final cleanup remain module-owned, so a test cannot forget
cleanup. A harness value retained beyond the closure is already closed.

The module-owned cleanup path is nonthrowing and invokes cleanup from the scope
task rather than from a store delegate callback. A test may call the public
`harness.store.close()` earlier; final cleanup then relies on the store's
idempotent close contract. Public `TransactionStore.close()` keeps its
reentrancy error for general lifecycle owners; that error is not part of the
scoped testing API's final cleanup.

`TransactionStoreTestClock` is a separate testing primitive for the component
that actually owns a time dependency, such as an app transaction delegate or
ViewModel. That component accepts `any Clock<Duration>` using Swift's
primary-associated-type syntax. The test retains the concrete clock so it can
observe registered sleepers and advance virtual time. The clock uses
synchronized checked storage, such as `Synchronization.Mutex`; its synchronous
`Clock` requirements are not actor-isolated. Its independent virtual `Instant`
cannot be mixed with a `ContinuousClock.Instant` deadline.

The test harness consumes the nested typed Product ID and the group type. It
validates that the group is present in the supplied catalog, then uses the
catalog's normalized raw Product ID and group ID. It never accepts an
`Entitlement` as a purchase command because mapping an entitlement back to one
monthly or yearly Product ID is not defined. Direct entitlement sets belong to
the fixed override initializer, not the full-pipeline harness.

Initialization completes an empty current-entitlement query before returning.
The initial public state is therefore `.ready` with empty raw and typed
collections, not a racing `.loading` state. A test that needs to inspect loading
or failure transitions uses a lower-level package contract test rather than
adding timing hooks to app code.

The initial public command surface contains only `purchase`. Expiration and
revocation are not aliases for removing a Product ID from the fake current set:
a natural expiration is a status/current-entitlement transition, while a
revocation is a revised durable transaction delivery. Each needs an explicit
transaction-identity, delegate-policy, finish, and missing-active-transaction
contract before it can become public.

### Causal action acknowledgement

Every mutating harness method is its own completion receipt. For example,
`purchase(_:,in:)` returns only after all work caused by that command has
completed:

1. The synthetic transaction is admitted to the source.
2. The command attaches a direct-operation receipt and reporting authority to
   the production runtime rather than yielding through the background update
   stream.
3. The delegate or default resolver produces a policy; throwing terminates the
   command through the failure-routing contract.
4. `.automatic` resolves from catalog classification. A resolved or explicit
   `.finish` acknowledges the synthetic transaction; `.keepUnfinished` leaves it
   available to a later attempt.
5. Current entitlements are queried and reconciled without deciding the same
   exact revision again in this causal attempt.
6. The subscription catalog validates and projects the candidate.
7. `TransactionStore` commits the resulting availability on `@MainActor`.

The command returns `.completed(transaction)` for resolved or explicit
`.finish`, and `.keptUnfinished(transaction)` for `.keepUnfinished`. Both
outcomes are returned after MainActor publication, so a ViewModel property
computed directly from `store.isEntitled(to:)` can be read immediately. A
thrown delegate or automatic-handling error instead fails the command and
produces neither outcome. The receipt does not guarantee a SwiftUI render pass
or completion of an unstructured consumer `Task` launched by an observation
callback; that work needs its own owner-provided acknowledgement.

The harness does not expose “wait until globally idle.” StoreKit-style monitors
are intentionally long-lived, so process-wide quiescence is not a meaningful
state. A future batch API may expose a cutoff receipt for commands admitted
before a sequence number, but it must not define completion as all producer
tasks exiting.

### Clock contract

The Clock controls a real time-dependent suspension in the code under test; it
does not manufacture completion for an otherwise immediate harness command.
For example, an app can inject `any Clock<Duration>` into its transaction
delegate. The test supplies `TransactionStoreTestClock`, retains the concrete
value, and synchronizes advancement with its explicit registration barrier:

```swift
final class DelayedTransactionDelegate: TransactionStoreDelegate {
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func transactionStore(
        decidePolicyFor transaction: StoreTransactionSnapshot
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

`waitUntilPendingSleepCount(reaches:)` returns when at least that many pending
sleeps have registered. This is the same boundary as waiting until a dependency
has reached its controlled suspension point before asserting intermediate
state. The implementation uses an awaitable continuation-backed barrier rather
than a fixed sleep or a guessed number of `Task.yield()` calls. Cancelling the
barrier throws `CancellationError`.

Advancing the Clock only makes due sleepers runnable; `purchase.value` remains
the pipeline receipt. Negative clock advances and negative sleeper counts are
programmer errors and fail immediately. Cancelling a sleeping task removes its
sleeper and throws `CancellationError` according to the standard Clock
contract.

### Harness lifecycle and coverage boundary

The scoped function stops command admission and drains already admitted work
before closing the underlying store. Cancellation of the task awaiting an
already admitted command does not silently cancel durable transaction decisions;
scope cleanup still establishes terminal completion. The scope drains only
framework-owned work. A consumer task started inside `operation` remains owned
by that operation and must reach its own terminal state before the closure
returns.

The harness captures background failures in `reportedFailures` and forwards
explicit command errors to the command caller without also appending them as a
background failure. To preserve that ownership rule, `StoreTransactionKit`
exposes a package-scoped Session/TransactionStore seam that stages the synthetic
current state and delegates the command to the runtime's attached direct
`process(_:leases:)` path. It does not use `StoreTransactionSource.runUpdates`
for explicit commands. The harness's forwarding delegate captures background
notifications and, when supplied, forwards decisions and notifications to the
app delegate. No public raw transaction-source protocol or fake
`TransactionStore` is required.

This layer proves the app catalog, StoreTransactionKit pipeline, and consumer
state integration. The app-hosted `.storekit` suite remains the owner of the
live StoreKit adapter, verification results, StoreKit Test session behavior,
and system integration.

## Required contract tests

### Catalog tests

- Every declared monthly and yearly Product ID maps to its expected entitlement.
- Multiple groups compose into one catalog without type erasure at the call site.
- `including(_:)` does not change the original catalog or share mutable storage.
- An empty `SubscriptionGroupID` fails when the ID value is constructed.
- Empty Product IDs, empty groups, duplicate group IDs, and duplicate Product
  IDs fail during catalog construction.
- Duplicate entitlement values remain valid.
- Each `AutoRenewableSubscriptionCatalogError.errorDescription` identifies the
  Product ID and relevant expected or actual metadata.
- Known Product ID with a wrong product type fails projection.
- Known Product ID with a wrong or missing group ID fails projection.
- Unknown non-upgraded Product ID inside a managed group fails projection.
- Unknown Product ID outside managed groups remains raw and is ignored by the
  typed set.
- A catalog mismatch in one included group fails the complete composed
  projection.
- Known and unknown upgraded transactions remain raw, do not require a current
  catalog entry, and do not grant typed access.

### State-owner tests

- Initial state is `.loading` with both projections `nil`.
- Override initialization publishes `.overridden`, leaves raw `entitlements`
  `nil`, and normalizes duplicate input values into one typed set.
- An empty override sequence publishes `.overridden` with an empty, non-`nil`
  `activeEntitlements` set.
- Override membership queries return exact set membership.
- Every StoreKit-specific operation on an override store throws
  `operationUnavailableInOverride(operation:)` without changing state or
  invoking a delegate method; repeated `close()` calls succeed.
- A successful empty query produces `.ready` and two empty collections.
- Startup query, transaction-handling, and catalog failures produce `.failed`
  without a partial candidate snapshot when no earlier query has succeeded.
- A later success recovers `.failed` to `.ready` atomically.
- A late startup query failure after a background success preserves `.ready`.
- Explicit and background query or transaction-handling errors after `.ready`
  preserve the previous raw and typed snapshot.
- A verified known-tier to unknown-tier change produces `.failed`, clears both
  public projections, and makes `isEntitled(to:)` return `false`.
- A coalesced catalog failure does not publish a partial raw or typed snapshot.
- Observation never publishes a status/projection combination outside the state
  table.
- `withObservationTracking` observes `isEntitled(to:)` through the private
  availability value.
- `isEntitled(to:)` returns `false` for `.loading`, `.failed`, and an available
  set without the value, and `true` for a matching ready or overridden
  entitlement.

### Coordination and reporting tests

- `.automatic` calls StoreKit `finish()` only for a catalog-validated managed
  transaction; an explicit `.finish` is the only other path to `finish()`.
- `.automatic` also finishes an upgraded transaction in a managed group after
  validating `.autoRenewable`, without requiring its retired Product ID to
  remain declared or granting typed access.
- `.automatic` throws `unhandledTransaction` for every unmanaged product, while
  invalid catalog metadata for a non-upgraded transaction fails before the
  delegate is called. Neither path finishes the transaction.
- Completed-revision suppression is bounded; an evicted exact revision can be
  decided again and therefore still requires app-level idempotency.
- `.keepUnfinished` calls neither `finish()` nor
  `transactionStore(didFailWith:)`, returns `.keptUnfinished` to a direct
  caller, and still completes the causal entitlement publication.
- A revision kept unfinished is decided at most once while its causal receipt is
  active across direct, update, and unfinished delivery paths, including
  coalesced reservations, and can be decided again only after that receipt
  completes.
- A thrown decision error stops candidate publication, reaches an attached
  direct caller without a duplicate notification, or reaches
  `transactionStore(didFailWith:)` once for background-owned work.
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
- The store retains its delegate until lifecycle completion, and `close()`
  drains admitted decisions and notifications.
- A delegate that implements only `transactionStore(didFailWith:)` inherits
  `.automatic` and receives an unmanaged background transaction as an
  `unhandledTransaction` failure.
- Propagated callback context rejects direct and `Task {}` reentry into
  admission-bearing store operations. A detached task does not inherit that
  context; the contract test documents the detection boundary without claiming
  that detached reentry throws.
- The default no-op `transactionStore(didFailWith:)` does not block the runtime
  or alter transaction policy.

### Integration and distribution tests

- App-hosted StoreKit tests cover monthly/yearly mapping, upgrades, a known-tier
  to unknown-tier transition, restore, revocation, and recovery without fixed
  sleeps.
- The external consumer fixture builds the README story using only public API.
- A second external fixture imports `StoreTransactionKitTesting`, starts from a
  ready empty set, purchases a typed Product ID, and observes the ViewModel
  change immediately after the command returns without a `.storekit` file.
- A harness purchase uses the attached direct-operation path: a delegate,
  automatic-handling, or catalog failure reaches the command caller and is not
  duplicated in `reportedFailures`; `.completed` and `.keptUnfinished` return
  only after MainActor publication.
- A time-dependent consumer dependency reaches a registered Clock sleeper,
  exposes its intermediate state, advances virtual time, and still waits for
  the harness command's MainActor publication receipt. The test contains no
  fixed sleeps or guessed `Task.yield()` counts.
- `withTransactionStoreTestHarness` drains and closes after normal return,
  operation failure, and cancellation; an operation failure is rethrown only
  after cleanup.
- Final scoped cleanup succeeds idempotently when the operation already called
  `harness.store.close()`.
- Cancellation before command admission creates no transaction; cancellation
  after admission is still drained by scoped cleanup.
- The testing product cannot be imported transitively by a consumer that
  depends only on the production product.
- Swift 6 strict-concurrency builds prove the primary-associated-type and
  `Clock` existential, class and actor delegate conformances, and `Sendable`
  surfaces.
- DocC builds without warnings after symbol documentation is added.

## Implementation transaction

This public redesign is complete only when one change updates all of the
following:

- Public source and symbol documentation.
- Unit and app-hosted StoreKit tests.
- The `StoreTransactionKitTesting` product, its one-way target dependency, and
  package-scoped production seams used by its synthetic source.
- Production and testing external consumer fixtures.
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
- [`WKNavigationDelegate`](https://developer.apple.com/documentation/webkit/wknavigationdelegate)
- [`WKNavigationResponsePolicy`](https://developer.apple.com/documentation/webkit/wknavigationresponsepolicy)
- [`TaskLocal`](https://developer.apple.com/documentation/swift/tasklocal)
- [`Task.detached(priority:operation:)`](https://developer.apple.com/documentation/swift/task/detached(priority:operation:))
- [`SendableMetatype`](https://developer.apple.com/documentation/swift/sendablemetatype)
- [`Clock`](https://developer.apple.com/documentation/swift/clock)
- [SE-0329: Clock, Instant, and Duration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md)
- [Using Continuations and Clock for deterministic Swift concurrency tests](https://zenn.dev/kntk/articles/2e8d1925b0bb6b)
- [StoreKit 2 subscription implementation walkthrough](https://www.revenuecat.com/blog/engineering/ios-in-app-subscription-tutorial-with-storekit-2-and-swift-jp/)
