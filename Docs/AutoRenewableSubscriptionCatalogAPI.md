# Auto-renewable subscription API design

Status: Proposed for the next beta API.

This document is the source of truth for the proposal. The README presents its
consumer-facing shape and labels it as proposed; the public source and symbol
documentation continue to describe the currently released API until the
implementation transaction is complete. After implementation, the public
contracts move to symbol DocC and a consumer article, and this temporary design
document is removed.

## Purpose

StoreTransactionKit needs to translate StoreKit Product IDs into the app's
feature-access vocabulary without making Product IDs themselves the public
entitlement type. The first consumer is an app with one App Store Connect
auto-renewable subscription group containing multiple access levels and
multiple durations at each level.

The same entitlement domain must support an app-selected StoreKit bypass and
deterministic app or ViewModel tests. Those paths use the production state and
transaction pipeline without inventing StoreKit transactions in app code.

## Goals

- Scope the Product ID type to one auto-renewable subscription group.
- Map multiple billing durations at one access level to one app entitlement.
- Make the subscription declaration the single source of catalog membership and
  app entitlement mapping.
- Keep StoreKit group levels and renewal periods in StoreKit rather than copying
  them into the catalog.
- Validate every piece of verified transaction metadata that the static catalog
  can know.
- Publish raw and typed entitlement state as one atomic snapshot.
- Distinguish unavailable entitlement state from an available empty set.
- Keep normal app UI usable while entitlement state is unavailable.
- Finish automatically only for a catalog-validated auto-renewable transaction.
- Give other product types an explicit app-owned handling decision.
- Make every background-owned failure observable without requiring a delegate.
- Allow fixed entitlement overrides without framework-owned environment checks.
- Let tests drive the production pipeline without a `.storekit` file or timing
  guesses.
- Make terminal shutdown and the single-live-store invariant enforceable.

## Non-goals

- The initial catalog does not compose multiple subscription groups. Supporting
  that requires per-group availability and failure isolation rather than one
  all-or-nothing entitlement projection.
- The catalog does not describe consumables, non-consumables, or non-renewing
  subscriptions.
- The catalog does not own prices, localized merchandising, purchase UI,
  renewal UI, or `Product.SubscriptionInfo.Status`.
- The framework does not infer app access from StoreKit `groupLevel`.
- The framework does not infer an entitlement for an undeclared Product ID.
- The framework does not detect TestFlight, previews, debug builds, receipts,
  or other environments to select override mode.
- The no-configuration test harness does not validate StoreKit verification,
  JWS, App Store Connect metadata, system purchase UI, or StoreKit renewal
  scheduling.
- Advancing a test clock does not mean that the transaction pipeline is idle or
  that an entitlement publication has completed.
- Source compatibility with the current Product-ID-as-entitlement API is not a
  goal while the package is beta.

## StoreKit model

An App Store Connect subscription group contains auto-renewable subscriptions
with different access levels and durations. A customer holds one subscription
in a group at a time. Subscriptions at one level may have monthly and yearly
variants.

StoreKit owns these facts:

- `Product.SubscriptionInfo.subscriptionGroupID` identifies the group.
- `Product.SubscriptionInfo.groupLevel` orders upgrade and downgrade paths;
  level `1` is the highest service level.
- `Product.SubscriptionInfo.subscriptionPeriod` describes the renewal period.
- `Transaction.currentEntitlements` includes current non-consumables,
  qualifying auto-renewable subscriptions, and non-renewing subscriptions. It
  excludes consumables.

The app owns access meaning. `SubscriptionEntitlement.tier1` is an app-domain
value, not a copy of `groupLevel == 1`. The explicit Product ID mapping is the
boundary between those models.

## Consumer story

Define the app entitlements and the Product IDs belonging to one subscription
group:

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

Create one live store at the process composition root and inject that same
instance into SwiftUI:

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

Gate only the paid feature. Loading or a failed entitlement query does not
replace the rest of the view:

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

Monthly and yearly subscriptions granting the same access map to the same
entitlement. StoreKit owns upgrade and downgrade ordering. If several plan
identities grant one feature, the app checks the accepted entitlement values;
the catalog does not infer tier inclusion.

No active subscription is represented by `.ready` with an empty
`activeEntitlements` set. It is distinct from `.loading` or `.failed`, where
`activeEntitlements` is `nil`.

For an app-defined environment that bypasses StoreKit, provide the exact set to
activate:

```swift
let store = TransactionStore(
    subscriptionCatalog: subscriptionCatalog,
    overridingEntitlements: [
        SubscriptionEntitlement.tier1,
        .tier2,
    ]
)
```

The app owns the condition selecting this initializer. An empty sequence means
override mode with no active entitlement.

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

public struct StoreSubscription<ProductID, Entitlement>:
    Sendable
where
    ProductID: RawRepresentable<String> & Hashable & Sendable,
    Entitlement: Hashable & Sendable
{
    public let id: ProductID
    public let entitlement: Entitlement

    public init(
        _ id: ProductID,
        entitlement: Entitlement
    )
}

@resultBuilder
public struct StoreSubscriptionsBuilder<ProductID, Entitlement>
where
    ProductID: RawRepresentable<String> & Hashable & Sendable,
    Entitlement: Hashable & Sendable
{
    public typealias Element =
        StoreSubscription<ProductID, Entitlement>

    public static func buildExpression(
        _ expression: Element
    ) -> Element

    public static func buildBlock(
        _ first: Element,
        _ rest: Element...
    ) -> [Element]
}

public protocol AutoRenewableSubscriptionGroup<Entitlement> {
    associatedtype Entitlement: Hashable & Sendable
    associatedtype ProductID:
        RawRepresentable<String> & Hashable & Sendable

    static var id: SubscriptionGroupID { get }

    @StoreSubscriptionsBuilder<
        Self.ProductID,
        Self.Entitlement
    >
    static var subscriptions: Self.StoreSubscriptions { get }
}

public extension AutoRenewableSubscriptionGroup {
    typealias StoreSubscriptions =
        [StoreSubscription<ProductID, Entitlement>]
}

public struct AutoRenewableSubscriptionCatalog<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    public init<Group>(_ groupType: Group.Type)
    where Group: AutoRenewableSubscriptionGroup<Entitlement>
}

public enum AutoRenewableSubscriptionCatalogError: LocalizedError, Sendable {
    case undeclaredProduct(
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
    case refreshEntitlements
    case history
    case restorePurchases
    case close
}

public enum StoreTransactionError: Error, Sendable {
    public enum CompletedOperation: Sendable, Hashable {
        case finishedTransaction(StoreTransactionSnapshot)
        case synchronizedPurchases
    }

    case closing
    case closed
    case unknownPurchaseResult
    case unhandledTransaction(
        productID: Product.ID,
        productType: Product.ProductType
    )
    case reentrantOperation(operation: StoreTransactionOperation)
    case operationUnavailableInOverride(
        operation: StoreTransactionOperation
    )
    case entitlementRefreshFailed(
        after: CompletedOperation,
        underlyingError: any Error
    )
}

public enum StoreTransactionHandlingPolicy: Sendable, Hashable {
    case automatic
    case finish
}

public protocol TransactionStoreDelegate: AnyObject, Sendable {
    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy

    func didFail(
        with failure: StoreTransactionBackgroundFailure
    ) async
}

public extension TransactionStoreDelegate {
    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        .automatic
    }

    func didFail(
        with failure: StoreTransactionBackgroundFailure
    ) async {}
}

public enum StorePurchaseOutcome: Sendable, Hashable {
    case completed(StoreTransactionSnapshot)
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

`StoreTransactionError` is not `Hashable`: the post-completion failure preserves
an arbitrary underlying error, and no consumer requires errors as collection
keys.

## Catalog contract

### Type-safety boundary

The nested Product ID type prevents a Product ID declared for another group
from being passed to a group-specific API. The primary associated type in
`AutoRenewableSubscriptionGroup<SubscriptionEntitlement>` fixes the app
entitlement type at the conformance, and the builder then accepts only that
group's `ProductID` and entitlement values. `SubscriptionGroupID` prevents group
IDs from being confused with Product IDs. Feature code sees the app's
`Entitlement`, not raw identifiers.

`subscriptions` is the single source of catalog membership and mapping.
Declaring a case or static member on `ProductID` does not by itself make that
identifier a managed subscription; a `StoreSubscription` entry does.
The catalog therefore does not require `CaseIterable` or reconcile a second
list of identifiers with the builder output.

The compiler cannot validate App Store Connect. Runtime validation is therefore
part of the catalog contract. The name `SubscriptionGroupID` mirrors StoreKit's
`subscriptionGroupID`; the auto-renewable qualifier belongs on the group and
catalog types that define subscription scope.

The client-conformance protocol stays intentionally small. The catalog consumes
`subscriptions` synchronously and stores normalized strings, entitlement values,
and the `ObjectIdentifier` of the declaring group type. It retains no group
instance, group metatype, or typed Product ID. The declaration identity is used
only to prevent a testing command from substituting another conformance with
the same raw identifiers but a different mapping. Future optional metadata
belongs in a configuration value or catalog initializer rather than a new
protocol requirement.

### Apple API analog

This declaration shape follows the Xcode 27 `Evaluations` framework in three
places: `Evaluation.Evaluators` resolves a nested collection alias from a
conformance's associated types, `EvaluatorsBuilder` makes that collection
declarative, and `Evaluator` provides an inline concrete element. Here,
`StoreSubscriptions` resolves to an array of inline `StoreSubscription` values.

This is an API-shape analog only. StoreTransactionKit does not import
`Evaluations`, and adopting the shape does not raise the package's deployment
targets to OS 27.

The collection property is named `subscriptions`, matching
`SubscriptionStoreView.init(subscriptions:)`. The unqualified `Subscription`
and `Subscriptions` names are not used: Combine already exports a protocol and
namespace with those exact names. `StoreSubscription` and
`StoreSubscriptions` retain the subscription vocabulary while avoiding that
collision. The enclosing group and catalog types retain the `AutoRenewable`
qualifier because they define the StoreKit product scope.

The analogy stops at the storage boundary. Evaluations needs
`any EvaluatorProtocol<Sample, Subject>` because one list can contain different
evaluator implementations. Every subscription entry has the same
`ProductID`-plus-`Entitlement` shape, so StoreTransactionKit uses one generic
value and introduces no per-subscription protocol, existential, closure-backed
mapping, or type erasure.

The group remains a static schema and the catalog initializer continues to take
its metatype. `buildExpression` gives each `StoreSubscription` initializer the
group's concrete `ProductID` and `Entitlement` context. The builder DSL exposes
only those element expressions and flat `buildBlock` composition; it does not
add optional, either, or array syntax. A witness getter can bypass the builder
transformation with an explicit `return`, so the API does not claim to make
runtime-dependent declarations unrepresentable. The catalog evaluates the
getter once during construction, snapshots that returned declaration, and does
not observe later getter results.

### Construction

`SubscriptionGroupID.init(rawValue:)` preconditions that its value is not empty.
Catalog construction evaluates the static subscription declaration once,
performs no StoreKit request, and preconditions that:

- At least one subscription is declared.
- Every Product ID raw value is nonempty.
- No raw Product ID is repeated within the group.

These are static programmer errors, so the initializer remains nonthrowing.
Duplicate entitlement values are valid and expected for monthly and yearly
subscriptions at one access level. Declaration order has no semantic meaning;
the catalog normalizes entries into its lookup.

### Runtime validation and projection

A Product ID is declared only when it appears in a `subscriptions` entry. For
each verified transaction in a candidate `StoreEntitlements` snapshot, the
catalog applies these rules before publication:

1. A declared Product ID must have `productType == .autoRenewable`.
2. A declared Product ID must have the catalog's subscription group ID.
3. A declared, non-upgraded transaction maps to its typed entitlement.
4. A declared transaction with `isUpgraded == true` remains raw but grants no
   typed access.
5. An undeclared, non-upgraded Product ID in the catalog's group fails with
   `undeclaredProduct`; the framework cannot infer its access meaning.
6. An undeclared upgraded transaction in the catalog's group is accepted only
   when its type is `.autoRenewable`; any other type fails with
   `productTypeMismatch`. A valid upgraded transaction remains raw, can be
   finished by `.automatic`, and grants no typed access. This permits retiring
   a Product ID after no supported customer can hold it as current.
7. A product outside the catalog's group remains raw and is ignored by the
   typed projection.

Every applicable transaction is validated before anything is published.
Successful mappings form a `Set`, so multiple durations can produce one
entitlement value.

The catalog is a closed declaration of the group it manages. Adding a product
in App Store Connect can therefore make an older binary report
`undeclaredProduct` after a customer moves to it. Product rollout must account
for supported older app versions; guessing a tier could grant the wrong access.

## Transaction handling policy

The catalog classifies each verified transaction before the delegate runs:

- A **managed** transaction is a catalog-declared, metadata-valid
  auto-renewable transaction. An undeclared upgraded transaction in the managed
  group is also managed for finishing after its type and group are validated,
  but it cannot grant typed access.
- An **invalid** transaction is declared with the wrong type or group, is an
  undeclared non-upgraded product inside the managed group, or is an undeclared
  upgraded product in that group whose type is not `.autoRenewable`. It fails
  before the delegate runs and is never finished.
- An **unmanaged** transaction belongs outside the catalog, such as a
  consumable, non-consumable, non-renewing subscription, or an auto-renewable
  subscription in another group.

The delegate decision is requested for managed and unmanaged transactions:

- `.automatic` finishes a managed transaction and throws
  `unhandledTransaction` for an unmanaged one. It is not unconditional finish.
- `.finish` means the app has durably applied this business event, or its
  idempotency ledger proves that the event was already applied. The framework
  then calls `finish()`.
- If `decidePolicy(for:)` throws, the framework does not call `finish()` and
  does not run the causal entitlement refresh. A direct operation throws the
  error; background-owned work reports it. A later independent StoreKit
  delivery can present the exact revision again. The framework starts no timer
  or backoff retry.

There is no normal “keep unfinished” policy. StoreKit may still include an
unfinished auto-renewable transaction in `Transaction.currentEntitlements`, so
not calling `finish()` does not guarantee that access is withheld. A future
deferral feature would need transaction suppression and a corresponding public
availability state, not only another policy case. StoreKit purchase deferral is
already represented by `StorePurchaseOutcome.pending`.

The decision/notification split follows the same structure as
`WKNavigationDelegate`: one method returns policy before a consequential action;
the other reports a failure that has already occurred and returns no policy.
Both requirements have defaults, so the delegate is optional and may implement
only the behavior it owns.

The protocol is class-bound and `Sendable`, but not actor-bound. Its public
contract describes isolation requirements rather than prescribing whether a
consumer uses an actor or a synchronized class.

### Exact-revision ownership

Direct purchase results, `Transaction.updates`, and `Transaction.unfinished`
reconciliation attach to one causal decision receipt for an exact transaction
revision. Coalesced deliveries share that receipt instead of repeating delegate
work. The receipt stays active through policy, `finish()`, causal refresh, and
ordered MainActor publication.

After `finish()` succeeds, the exact revision enters a bounded process-local
completed cache. The cache suppresses nearby duplicate deliveries but is not a
durable business ledger. Eviction may allow the revision to be presented again,
so every app-owned effect remains idempotent. Revision identity includes changes
such as revocation; transaction ID alone is not sufficient.

### Failure after a completed action

If `process(_:)` finishes a transaction and its causal entitlement refresh then
fails, it throws:

```swift
StoreTransactionError.entitlementRefreshFailed(
    after: .finishedTransaction(transaction),
    underlyingError: error
)
```

The exact revision is already recorded as completed. The consumer must not
reapply its business effect, repeat a purchase, or rerun `process(_:)` only to
recover. Its next operation is `refreshEntitlements()`.

`StorePurchaseOutcome.completed` is returned only after policy, finish, refresh,
catalog projection, and atomic MainActor publication all complete. A
post-finish refresh failure returns no outcome and throws the typed error above.

If `AppStore.sync()` itself fails, `restorePurchases()` throws the original
error. If synchronization succeeds and the following refresh fails, it throws
`entitlementRefreshFailed(after: .synchronizedPurchases, underlyingError:)`.
The consumer retries `refreshEntitlements()` rather than immediately presenting
restore authentication again.

The physical refresh coordinator completes with the root refresh or catalog
error only. Each attached direct receipt adds its own completed-action context:
a process receipt whose finish succeeded creates `.finishedTransaction`, a
restore receipt whose sync succeeded creates `.synchronizedPurchases`, and a
plain refresh receipt returns the root error unchanged. This remains correct
when those callers coalesce into one physical batch.

If the physical failure is background-owned, the entitlement-refresh background
failure also stores the root error rather than one caller's completed-action
wrapper. Observable `EntitlementStatus` stores that same root error because it
explains readiness. Completed revisions and restore completion remain recorded
by their respective operation owners.

## Fixed entitlement override

`overridingEntitlements` is a composition-root choice, not mutable runtime
state. The initializer consumes a finite sequence, normalizes it once to a
`Set`, and publishes `.overridden` immediately. An empty sequence is an
authoritative empty set; it does not select live StoreKit behavior.

An override store:

- Starts no StoreKit source, monitor, query, or transaction processing.
- Does not retain or invoke a delegate.
- Publishes the normalized typed set and answers exact membership queries.
- Keeps raw `entitlements == nil`; it invents no StoreKit snapshots.
- Throws `operationUnavailableInOverride(operation:)` from every StoreKit
  operation before starting work.
- Makes `close()` successful and idempotent.

The app owns whether a preview, internal build, TestFlight build, UI test, or
another environment uses this initializer. There is no “unlock everything”
Boolean because the framework does not know the app's complete entitlement
universe.

The catalog remains an initializer argument so live and override composition
share the same entitlement domain. No entitlement is reverse-mapped to a
Product ID because several products can intentionally grant the same value.

## Atomic entitlement publication

Raw and typed entitlement values describe one StoreKit query and commit
together. Projection and validation run inside the entitlement refresh
coordinator after unfinished processing and before any snapshot is exposed or
any receipt completes.

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
```

One reducer owns the public state:

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
that value. There are no independently mutated mirror properties.

| Status | `entitlements` | `activeEntitlements` | Meaning |
| --- | --- | --- | --- |
| `.loading` | `nil` | `nil` | No readiness attempt has completed. |
| `.failed(error)` | `nil` | `nil` | No usable complete snapshot exists. |
| `.ready` | non-`nil` | non-`nil` | A complete live snapshot is available; empty means no entitlement. |
| `.overridden` | `nil` | non-`nil` | The app-supplied set is authoritative; empty means no entitlement. |

State transitions are:

| Event | Result |
| --- | --- |
| Live initialization | `.loading`. |
| Override initialization | `.overridden` with the normalized set. |
| Successful candidate | `.ready` with one new atomic snapshot. |
| Query or transaction-handling failure with no prior snapshot | `.failed(error)`. |
| Query or transaction-handling failure after `.ready` | Preserve the last `.ready` snapshot. |
| Catalog failure | `.failed(error)` and clear both projections, even after `.ready`. |
| Successful empty query | `.ready` with two empty collections. |
| Unverified current-entitlement element | Omit it, report it, and publish the verified remainder. |
| Close | Preserve the last entitlement state. |

A catalog contradiction fails closed because preserving an older typed set could
continue granting a higher tier after a move to an undeclared lower-tier
product. A transient query failure preserves a known-good ready snapshot.

`isEntitled(to:)` performs exact membership in `.ready` and `.overridden`. It
returns `false` while loading, after a readiness failure, or when the available
set does not contain the value. Consumers inspect `entitlementStatus` only when
they need to explain the reason.

## Failure routing and observability

Failure delivery follows ownership of the physical work:

| Failure | Observable state | Direct caller | Background owner |
| --- | --- | --- | --- |
| Invalid static catalog | Store is not created | None | `precondition` failure |
| StoreKit operation in override mode | Preserve `.overridden` | Throw `operationUnavailableInOverride` | None |
| Explicit query or handling failure | Fail or preserve according to the state table | Throw | No duplicate report while attached |
| Startup or background query/handling failure | Fail or preserve according to the state table | None | Record and optionally notify once |
| Explicit catalog failure | Invalidate projections | Throw | No duplicate report while attached |
| Startup or background catalog failure | Invalidate projections | None | Record and optionally notify once |
| Current-entitlement verification failure | Publish verified remainder | Attached operation may succeed | Record and optionally notify once |
| Post-finish or post-sync refresh failure | Apply the underlying refresh transition | Throw typed completed-action error | Record and optionally notify once when background-owned |

Every physical batch has one reporting authority. Direct participation is bound
at admission, before work can fail. If any attached direct caller receives the
error, it is not also a background failure. If all direct callers abandon the
work, ownership transfers to the background authority and the error is reported
once.

Every background-owned failure is first recorded through a package-owned
unified `Logger`, whether or not a delegate exists. A supplied delegate then
receives the same failure through `didFail(with:)`. Internal logging is
best-effort observability: it cannot change policy or completion, has no public
injection surface, and never records JWS data. Direct errors returned to an
attached caller are not logged as background failures.

For a failure that changes observable entitlement state, the reducer commit
completes before logging and before `didFail(with:)` begins. A delegate may
therefore inspect the corresponding state, but it cannot alter that state or
request retry by returning a value.

Background notifications are serialized with backpressure. Decisions are also
serialized, but decision and notification delivery are independent and may
overlap. `close()` drains both.

## Product-type boundary

`AutoRenewableSubscriptionCatalog` maps only auto-renewable subscriptions:

- Non-consumables and non-renewing subscriptions may appear in raw
  `StoreEntitlements` but do not produce typed catalog entitlements.
- Consumables never appear in `Transaction.currentEntitlements`; they still
  reach transaction handling. An app that owns a consumable balance supplies a
  delegate and returns `.finish` only after applying that balance durably.
- `.automatic` rejects every unmanaged product, so the default path never
  finishes a product with no business-effect owner.

`TransactionStore` remains the process-wide transaction monitor and finish
authority across product types. A future typed non-consumable catalog is a
separate design, not another member of `AutoRenewableSubscriptionGroup`.

## Ownership map

| Responsibility | Owner |
| --- | --- |
| Group ID, typed Product IDs, catalog membership, and entitlement mapping | App-defined `AutoRenewableSubscriptionGroup.subscriptions` |
| Catalog lookup and verified metadata validation | `AutoRenewableSubscriptionCatalog` |
| Choosing live or override mode | App composition root |
| Fixed override normalization and publication | `TransactionStore` availability owner |
| StoreKit query and unfinished reconciliation | `CurrentEntitlementReconciler` |
| Exact-revision admission, decision receipt, and completed cache | Transaction processing coordinator |
| Projection, refresh coalescing, ordered completion, and atomic publication | Entitlement refresh coordinator |
| Observable availability | `TransactionStore` reducer |
| Process-wide live-monitoring lease, admission, and shared close completion | Non-generic internal lifecycle authority |
| Exactly-once direct/background failure selection | Runtime reporting authority |
| Unified background logging | Runtime reporting authority and package logger |
| App-specific policy, durable effect, and failure reaction | App `TransactionStoreDelegate` |
| Product merchandising and subscription-status presentation | App using StoreKit directly |
| Synthetic source, command receipt, and test lifecycle | `StoreTransactionKitTesting` harness |
| Timed app behavior | The app component with an injected `Clock` |
| Virtual time and sleep-registration barriers | `TransactionStoreTestClock` |

No UI type owns semantic entitlement state, and no second Product ID mapping is
performed outside the catalog.

## Lifecycle and concurrency

### Live-store lease

The live initializer synchronously acquires one process-wide exclusive lease
before retaining a delegate or creating a StoreKit producer. A second live
initializer while that lease is active is a precondition failure. The lease is
shared across every generic specialization of `TransactionStore`.

The lease is held by a non-generic internal lifetime authority, not only by the
observable facade. `close()` releases it after terminal shutdown. Override
stores and synthetic stores created by `StoreTransactionKitTesting` do not
acquire it because they neither monitor live StoreKit sequences nor own live
`finish()` authority.

Dropping a store is not an awaitable replacement protocol. Code that needs a
different live store first awaits `close()`.

### Admission and cancellation

Each admission-bearing operation — `process(_:)`, `refreshEntitlements()`,
`history(for:)`, and `restorePurchases()` — checks cancellation immediately
before acquiring its operation lease. Successful lease acquisition is the
admission boundary.

- Cancellation before admission throws `CancellationError` and starts no
  operation-specific StoreKit work.
- Cancellation after admission abandons only that caller's wait. The physical
  decision, finish, refresh, publication, and failure routing continue to
  terminal completion.
- If the cancelled caller was the last direct observer of a later failure, that
  failure becomes background-owned and is reported once.
- `.pending` and `.userCancelled` results create no durable transaction work and
  check cancellation before returning.
- `close()` is the exception: it begins or joins terminal shutdown even when the
  caller is already cancelled, and every caller waits for the shared completion.

Admission-bearing operations accepted while running complete. New
admission-bearing operations after shutdown has been sealed throw `.closing`;
after terminal completion they throw `.closed`. Repeated `close()` calls still
succeed, and the last observable entitlement state remains readable.

### Delegate reentrancy

The store strongly retains its delegate until terminal shutdown. A delegate
that references the store must hold that reference weakly.

A delegate must not start an admission-bearing operation on the same store from
either callback. Inherited callback context lets the runtime reject direct calls
and `Task {}` child calls with
`reentrantOperation(operation:)`. `Task.detached` intentionally drops task-local
context, so Swift's actor isolation, `@isolated(any)`, `sending`,
`SendableMetatype`, and actor-context inheritance cannot prove that detached
call's ancestry. Starting a detached operation remains unsupported whether or
not the callback awaits it: awaiting can create a dependency cycle, while
fire-and-forget work escapes callback ownership. The contract does not claim
detached provenance is detectable.

A process-wide “callback active” gate is not used because it would reject
unrelated operations that merely overlap a suspended callback.

### Shared close

The first accepted `close()` publishes one shared, noncancellable completion
before suspending. Concurrent callers join it; calls after closure return
successfully without effect.

Before awaiting `AsyncSequence.next()`, each live producer acquires an iteration
lease. Sealing producer admission prevents a new `next()` call but does not
invalidate a lease already waiting for or handling an element. If an element is
returned while close races with that wait, the producer hands it to a processing
coordinator-owned, noncancellable terminal receipt before observing cancellation
and waits for that receipt without propagating producer cancellation into it.
Producer task cancellation interrupts the sequence wait, not physical work
admitted from a returned element.

Terminal shutdown executes in this order:

1. Transition to `closing`; seal public-operation admission and new producer
   iteration admission.
2. Cancel the startup waiter and StoreKit producer tasks.
3. Await producer termination; callbacks admitted before sealing remain
   admitted.
4. Await every admitted direct operation, decision, `finish()`, entitlement
   refresh, ordered publication, and causal receipt.
5. Seal and drain background-failure delivery.
6. Release the strongly retained delegate.
7. Release the live-store lease and enter `closed`.

After `close()` returns, no framework-owned task, StoreKit producer, delegate
invocation, or publication from that store remains active. The last entitlement
state remains readable.

Calling `close()` from a callback owned by the same store throws
`reentrantOperation(operation: .close)` because waiting for that callback is
part of close completion.

### Deinitialization backstop

`TransactionStore` uses `isolated deinit` only for synchronous containment. It
must synchronously seal public and producer admission, then signal cancellation
to startup, producers, and finite framework tasks. It does not start an
unstructured cleanup task, await callbacks, claim shutdown completion, or
release the live lease directly.

Runtime-owned work retains the lifetime token until every task admitted before
that seal terminates. Deinitialization does not promise a successful drain;
admitted work may instead reach terminal cancellation and background-failure
routing. Constructing another live store immediately after dropping an unclosed
one may therefore still fail the lease precondition. Explicit `close()` is the
only awaitable replacement boundary.

## Deterministic consumer testing

The package adds a second public SwiftPM product with a one-way dependency:

```text
StoreTransactionKitTesting
        ↓
StoreTransactionKit
```

Production targets import `StoreTransactionKit`. Test targets may import
`StoreTransactionKitTesting`, which creates a real `TransactionStore` around a
package-scoped synthetic source. It does not reimplement transaction handling,
catalog projection, or observable state.

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

    @discardableResult
    public func purchase<Group>(
        _ productID: Group.ProductID,
        in groupType: Group.Type
    ) async throws -> StoreTransactionSnapshot
    where Group: AutoRenewableSubscriptionGroup<Entitlement>
}

public enum TransactionStoreTestHarnessError:
    LocalizedError,
    Sendable,
    Hashable
{
    case subscriptionGroupMismatch(
        expected: SubscriptionGroupID,
        actual: SubscriptionGroupID
    )
    case subscriptionGroupTypeMismatch(
        subscriptionGroupID: SubscriptionGroupID
    )
    case undeclaredProduct(
        productID: String,
        subscriptionGroupID: SubscriptionGroupID
    )
    case operationUnavailable(operation: StoreTransactionOperation)

    public var errorDescription: String? { get }
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

The scoped function owns construction and cleanup. It closes and drains the
store before returning on success, failure, or cancellation, then rethrows the
operation error. A retained harness value is already closed after the scope.

Construction completes an empty synthetic entitlement query before invoking the
closure, so the initial state is `.ready` with empty raw and typed collections.
The harness validates that the supplied group and Product ID belong to the
catalog. It accepts a Product ID rather than an entitlement because an
entitlement cannot be reverse-mapped to one monthly or yearly product.

A group whose ID differs from the catalog throws
`subscriptionGroupMismatch(expected:actual:)`. A different group declaration
that reuses the same ID throws
`subscriptionGroupTypeMismatch(subscriptionGroupID:)`; the catalog's declaring
group and `subscriptions` mapping remain authoritative. A raw Product ID absent
from that declaration throws `undeclaredProduct(productID:subscriptionGroupID:)`.
All checks complete before synthetic transaction admission, invoke no delegate
method, and leave state unchanged.

`purchase(_:,in:)` returns only after:

1. The synthetic transaction is admitted through the production direct path.
2. The delegate or `.automatic` resolver returns a policy.
3. The synthetic transaction is acknowledged as finished.
4. Current synthetic entitlements are reconciled and projected.
5. `TransactionStore` publishes the resulting state on `@MainActor`.

It returns the completed `StoreTransactionSnapshot` only after that receipt
completes. Pre-admission harness validation and delegate decision failures throw
directly and are not duplicated as background failures. A refresh or projection
failure after synthetic acknowledgement follows the production
`entitlementRefreshFailed(after: .finishedTransaction(...))` contract.
Supplying a delegate tests the app's real policy decision; the harness does not
add a second public failure-capture state.

A later `purchase` of another Product ID in the same group removes the prior
snapshot from the synthetic current-entitlement set before the new causal
refresh. It neither retains that snapshot nor marks it `isUpgraded`. This
supports a deterministic tier1-to-tier2 ViewModel test while explicitly
modeling only an immediately effective active product, not App Store scheduling
or metadata for upgrades, downgrades, renewals, or billing retry. Expiration,
revocation, and superseded-transaction projection remain app-hosted or
package-level StoreKit scenarios until they have independent public command
contracts.

The harness exposes no “wait until globally idle”: monitoring tasks are
long-lived, so global quiescence is not meaningful. Each mutating command is its
own completion receipt and does not promise a SwiftUI render pass or completion
of consumer-owned unstructured tasks.

### Synthetic store operation matrix

The harness exposes its `TransactionStore` so production ViewModels use their
real dependency. That does not give the lease-exempt synthetic store live
StoreKit authority:

| Store surface | Synthetic behavior |
| --- | --- |
| Entitlement properties and `isEntitled(to:)` | Read the production availability reducer. |
| `refreshEntitlements()` | Reconcile and publish the synthetic current-entitlement set. |
| `close()` | Drain the synthetic runtime; repeated calls succeed. |
| `process(_:)` | Throw `operationUnavailable(operation: .processPurchase)` before inspecting or finishing a live transaction. |
| `history(for:)` | Throw `operationUnavailable(operation: .history)` before source work. |
| `restorePurchases()` | Throw `operationUnavailable(operation: .restorePurchases)` without calling `AppStore.sync()`. |

`purchase(_:,in:)` is the only public synthetic mutation command in the initial
surface. Unsupported store operations leave state unchanged and do not invoke
the delegate. A synthetic purchase exercises the production finish-decision
boundary against a synthetic acknowledgement; it never calls
`Transaction.finish()` on a live StoreKit value.

### Clock contract

The harness itself accepts no Clock because its production transaction work has
no delay, timeout, or retry policy. `TransactionStoreTestClock` is injected into
the app component that owns time, such as a delegate or ViewModel. Clock
advancement releases sleepers; the purchase receipt still proves entitlement
publication.

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

The registration barrier is continuation-backed; tests do not use fixed sleeps
or guessed `Task.yield()` counts. Negative clock advances and negative sleeper
counts are programmer errors. Cancelling a sleeper removes it and throws
`CancellationError` according to the `Clock` contract.

The public harness initially exposes only `purchase(_:,in:)` as a synthetic
mutation command. App-hosted `.storekit` tests remain responsible for the live
StoreKit adapter, verification, StoreKit Test session behavior, renewal
scheduling, restore UI, history, expiration, and revocation.

## Required contract tests

### Catalog and state

- Every monthly and yearly `StoreSubscription` maps to its expected
  entitlement.
- Empty group IDs, subscription declarations, and Product ID raw values fail at
  construction.
- Duplicate raw Product IDs fail; duplicate entitlement values remain valid.
- A typed Product ID that has no `subscriptions` entry is not a catalog member
  and is rejected by typed testing commands before admission.
- Known Product IDs with a wrong type or group fail projection.
- An undeclared non-upgraded Product ID in the managed group fails projection.
- An undeclared upgraded Product ID in the managed group with a non-auto-
  renewable type fails with `productTypeMismatch` before delegate policy.
- An external-group Product ID remains raw and does not enter the typed set.
- An upgraded managed-group transaction remains raw, grants no typed access,
  and can be handled without retaining a retired Product ID declaration.
- Initial live state, ready-empty state, failed state, and override-empty state
  preserve the state table's `nil` distinctions.
- Every publication changes raw state, typed state, and status atomically.
- Catalog contradictions clear stale access; transient refresh failures preserve
  an earlier ready snapshot.
- `isEntitled(to:)` is observed through the single availability owner and uses
  exact membership.

### Processing, failure routing, and lifecycle

- `.automatic` finishes only a validated managed auto-renewable transaction.
- `.finish` is the only app-selected path to finish an unmanaged transaction.
- A thrown decision performs no finish or causal refresh and is redeliverable.
- A post-finish refresh failure records the revision as completed, throws
  `entitlementRefreshFailed(after: .finishedTransaction(...))`, and recovers via
  `refreshEntitlements()` without repeating policy or finish.
- A sync failure throws its original error; a post-sync refresh failure throws
  the completed-operation error and recovers without repeating sync.
- When process, restore, and plain refresh receipts coalesce on one failed
  physical refresh, each direct caller receives its own wrapper or root error;
  an abandoned batch produces one background report containing the root error.
- `StorePurchaseOutcome.completed` is returned only after MainActor publication.
- Completed-revision suppression is bounded and never substitutes for an app
  ledger.
- Coalesced direct, update, and unfinished deliveries decide one exact revision
  once per active receipt.
- Direct errors are not duplicated as background logs or notifications; an
  abandoned direct failure transfers to the background owner once.
- Every background failure reaches the internal diagnostic sink once even with
  no delegate. A supplied delegate receives it after the related state commit.
- The store retains its delegate until close drains decisions and notifications.
- Direct and inherited child-task callback reentry is rejected. Detached reentry
  is documented as unsupported without claiming provenance detection.
- A second live initializer fails across different `Entitlement` types.
- Override and multiple synthetic stores do not consume the live lease.
- Close seals admission before producer shutdown, joins concurrent callers,
  ignores waiter cancellation, and releases the lease only after complete drain.
- A producer holding an iteration lease before `next()` processes an element
  returned concurrently with close; no later iteration begins after the seal,
  and close waits for its policy, finish, refresh, and publication.
- Close completion guarantees no later framework task, callback, or publication.
- Cancellation before admission starts no work; cancellation after admission
  detaches the caller and lets the operation complete under background ownership.
- Deinit cancellation retains the live lease until runtime termination.

### Testing and distribution

- After implementation, the external production fixture builds the README
  examples against public API.
- A testing fixture starts ready-empty, purchases a typed Product ID, and reads
  its ViewModel change immediately after the command returns without `.storekit`.
- Wrong group ID, substituted group declaration, and undeclared Product ID
  commands throw their testing errors before admission and leave state and
  delegate calls unchanged.
- A second purchase in the same group replaces the active synthetic product and
  publishes the newly mapped entitlement without retaining a synthetic upgraded
  snapshot.
- Harness validation and decision errors reach the command caller directly;
  failures after acknowledgement use the production completed-action wrapper.
- A synthetic store refreshes its synthetic set and closes normally; process,
  history, and restore throw `operationUnavailable` before live StoreKit work.
- Passing a real purchase result to a synthetic store cannot call live
  `Transaction.finish()` or bypass the process-wide live lease.
- Scoped cleanup drains after success, failure, and cancellation and remains
  idempotent if the operation called `store.close()`.
- A timed app dependency reaches a registered sleeper, exposes intermediate
  state, advances virtual time, and still awaits the purchase publication
  receipt without fixed sleeps.
- The test clock releases only due sleepers, removes cancelled sleepers, and
  resumes a cancelled sleep with `CancellationError`.
- The sleep-registration barrier handles multiple waiters and cancellation
  without polling; invalid negative advances or counts fail in subprocess
  precondition tests.
- App-hosted StoreKit tests cover monthly/yearly products, real upgrade and
  downgrade behavior, restore, renewal, expiration, revocation, and recovery.
- The testing product is not imported transitively by production consumers.
- Swift 6 strict-concurrency builds cover the specialized primary-associated-
  type conformance, nested `StoreSubscriptions` alias, generic
  `StoreSubscriptionsBuilder`, Clock existential, actor/class delegate, and
  Sendable surfaces.
- Symbol DocC and the consumer article build without warnings.

## Implementation transaction

The redesign is complete only when one change updates all of the following:

- Public source and symbol documentation.
- Unit and app-hosted StoreKit tests.
- The `StoreTransactionKitTesting` product and its one-way target dependency.
- Package-scoped production seams used by the synthetic source.
- Production and testing external consumer fixtures.
- The README examples, removal of their proposal label, and hosted DocC
  examples.
- Every dependent app and its resolved package revision.

Until that transaction lands, the README labels the consumer sketch as proposed
and the current symbol documentation remains authoritative for compilable API.
Once the contract is implemented, the proposal label is removed and the
contract moves into symbol DocC and a consumer article; this document is then
deleted. No compatibility alias or deprecated initializer is planned while the
package is beta.

## References

- [Offer auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
- [`Product.SubscriptionInfo.subscriptionGroupID`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/subscriptiongroupid)
- [`Product.SubscriptionInfo.groupLevel`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/grouplevel)
- [`Product.SubscriptionInfo.subscriptionPeriod`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/subscriptionperiod)
- [`Transaction.isUpgraded`](https://developer.apple.com/documentation/storekit/transaction/isupgraded)
- [`Transaction.currentEntitlements`](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- [`SubscriptionStoreView.init(subscriptions:)`](https://developer.apple.com/documentation/storekit/subscriptionstoreview/init(subscriptions:))
- [`Combine.Subscription`](https://developer.apple.com/documentation/combine/subscription)
- [`Combine.Subscriptions`](https://developer.apple.com/documentation/combine/subscriptions)
- [`Evaluation`](https://developer.apple.com/documentation/evaluations/evaluation)
- [`Evaluation.Evaluators`](https://developer.apple.com/documentation/evaluations/evaluation/evaluators-swift.typealias)
- [`EvaluatorsBuilder`](https://developer.apple.com/documentation/evaluations/evaluatorsbuilder)
- [`EvaluatorProtocol`](https://developer.apple.com/documentation/evaluations/evaluatorprotocol)
- [`Evaluator`](https://developer.apple.com/documentation/evaluations/evaluator)
- [`WKNavigationDelegate`](https://developer.apple.com/documentation/webkit/wknavigationdelegate)
- [`TaskLocal`](https://developer.apple.com/documentation/swift/tasklocal)
- [`Task.detached(priority:operation:)`](https://developer.apple.com/documentation/swift/task/detached(priority:operation:))
- [`Clock`](https://developer.apple.com/documentation/swift/clock)
- [SE-0329: Clock, Instant, and Duration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md)
- [Using Continuations and Clock for deterministic Swift concurrency tests](https://zenn.dev/kntk/articles/2e8d1925b0bb6b)
- [StoreKit 2 subscription implementation walkthrough](https://www.revenuecat.com/blog/engineering/ios-in-app-subscription-tutorial-with-storekit-2-and-swift-jp/)
