# Understanding transaction handling

Follow a transaction from admission through policy, finishing, entitlement
publication, failure ownership, and shutdown.

## Exact-revision processing

A direct `Product.PurchaseResult`, `Transaction.updates`, and
`Transaction.unfinished` can expose the same transaction. StoreTransactionKit
identifies a live delivery by the exact verified JWS revision. Concurrent
deliveries of that revision join one physical attempt instead of repeating
policy or `finish()`.

After finishing, the revision enters a bounded process-local cache that
suppresses nearby redelivery. The cache is neither durable nor an app business
ledger: process launch or eviction can present the revision again. If a
``TransactionStoreDelegate`` applies an app-owned effect, make that effect
durably idempotent for the business event. Transaction ID alone is insufficient
because a later signed revision can describe a revocation or another change.

## Policy and finishing

The catalog validates and classifies every verified transaction before asking
the delegate for ``TransactionStoreDelegate/decidePolicy(for:)``:

- A declared auto-renewable subscription with matching group metadata is
  managed. ``StoreTransactionHandlingPolicy/automatic`` and
  ``StoreTransactionHandlingPolicy/finish`` both allow finishing it.
- A product outside the catalog's group is unmanaged. `.automatic` throws
  ``StoreTransactionError/unhandledTransaction(productID:productType:)``;
  `.finish` allows finishing only after the app has durably handled it.
- Contradictory metadata or an undeclared current product inside the managed
  group fails catalog validation before the delegate runs and is never
  finished.

If the delegate throws, the framework does not finish the transaction or start
its causal entitlement refresh. A later independent StoreKit delivery opens a
new attempt; the framework adds no timer or retry loop.

For a successful purchase,
``TransactionStore/process(_:)`` returns
``StorePurchaseOutcome/completed(_:)`` only after policy, `finish()`, unfinished
reconciliation, catalog projection, and main-actor publication complete.
If the refresh fails after `finish()`, the method instead throws
``StoreTransactionError/entitlementRefreshFailed(after:underlyingError:)`` with
``StoreTransactionError/CompletedOperation/finishedTransaction(_:)``. Retry
``TransactionStore/refreshEntitlements()``; do not repeat the completed action.

The same boundary applies to restore. A synchronization failure is returned
directly. If `AppStore.sync()` succeeds and its following refresh fails,
``TransactionStore/restorePurchases()`` throws the completed-operation error
with ``StoreTransactionError/CompletedOperation/synchronizedPurchases``.

## Reconciliation and publication

The initial load and every entitlement refresh handle all verified unfinished
transactions before publishing `Transaction.currentEntitlements`. This keeps
the observable projection from running ahead of unfinished durable work.
Current entitlements that were finished by another process or device may still
appear without a local policy invocation.

``TransactionStore/entitlements``,
``TransactionStore/activeEntitlements``, and
``TransactionStore/entitlementStatus`` derive from one availability value:

| Status | Raw entitlements | Typed entitlements |
| --- | --- | --- |
| ``EntitlementStatus/loading`` | `nil` | `nil` |
| ``EntitlementStatus/failed(_:)`` | `nil` | `nil` |
| ``EntitlementStatus/ready`` | authoritative collection | authoritative set |
| ``EntitlementStatus/overridden`` | `nil` | authoritative app-supplied set |

An empty ready or overridden set means no entitlement; it is not unresolved.
A transient query or transaction-handling failure preserves an existing ready
snapshot. A catalog contradiction clears raw and typed projections and moves
to `.failed`, because stale typed access may be unsafe. A later successful
refresh publishes a new ready snapshot.

The catalog maps declared Product IDs to app entitlement values. It does not
copy StoreKit group levels or subscription periods into the entitlement type,
and multiple Product IDs may map to the same value. A transaction that StoreKit
marks as upgraded grants no typed access. The raw projection otherwise mirrors
the verified current-entitlement items StoreKit returns, including products
outside the managed group.

StoreKit excludes revoked or refunded transactions from current entitlements.
For billing retry, grace period, and renewal presentation, use
`Product.SubscriptionInfo.Status`; do not infer subscription status only from
snapshot dates.

## Failure ownership

An admitted physical failure has one delivery owner. While a direct caller
remains attached, the operation throws to that caller and does not also send the
same failure through the background callback. If every attached caller cancels
after admission, the physical work continues and the last abandonment transfers
failure ownership to the background path.

Background-owned failures are logged once and, when supplied, delivered once to
``TransactionStoreDelegate/didFail(with:)``. This includes update processing,
unfinished reconciliation, current-entitlement verification failures, and
abandoned direct operations. The callback is a notification after the failure;
it cannot change policy or request retry.

Failures that affect observable entitlement state commit that state before
notification begins. Notifications are serialized with backpressure and
``TransactionStore/close()`` drains every admitted notification. Policy
decisions are also serialized, but policy and notification execution may
overlap.

An unverified direct purchase throws ``StoreTransactionVerificationError`` to
its caller. An unverified background element is reported instead. Unverified
current-entitlement elements are omitted while the verified remainder can still
publish.

## Admission and cancellation

`process(_:)`, `refreshEntitlements()`, `history(for:)`, and
`restorePurchases()` check cancellation before crossing their admission
boundary. Pre-admission cancellation starts no physical work. After admission,
caller cancellation abandons only that caller's wait: policy, finishing,
refresh, publication, and any required background reporting continue.

When closing has sealed admission, a new operation throws
``StoreTransactionError/closing``. After shutdown completes, it throws
``StoreTransactionError/closed``. The override initializer has no StoreKit
backend and its StoreKit operations throw
``StoreTransactionError/operationUnavailableInOverride(operation:)``.

Delegate methods must not call an admission-bearing operation on the same
store. Such a call can wait behind the callback that is making it. Reentry with
inherited callback context throws
``StoreTransactionError/reentrantOperation(operation:)``. A detached task does
not inherit that detection context, but awaiting one from the callback still
creates the same dependency cycle and must also be avoided.

## Close and deinitialization

Create one live ``TransactionStore`` per process. A second live initializer is
a programmer error while the first store owns transaction monitoring and
finishing authority. Override stores and StoreTransactionKitTesting harnesses
do not consume that live-store lease.

The first ``TransactionStore/close()`` call atomically seals public and producer
admission and starts one terminal shutdown. Concurrent close calls join the same
completion, and caller cancellation does not abandon it. Shutdown stops StoreKit
producers, drains admitted producer elements and public operations, drains
transaction, refresh, restore, and failure workers, releases the delegate, and
then releases the live-store lease. The last entitlement state remains readable.

Calling `close()` from a callback owned by the same store throws a reentrancy
error. Production apps normally retain the store for process lifetime; explicit
close is primarily for controlled shutdown and tests.

An isolated deinitializer is only a synchronous containment backstop. It seals
new admission and signals cancellation to framework-owned work, but cannot await
callbacks or claim a successful drain. Admitted work retains lifecycle authority
until it terminates, so another live store may not be constructible immediately
after an unclosed store is released. `close()` is the only awaitable replacement
boundary.
