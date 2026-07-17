# Understanding transaction handling

How StoreTransactionKit turns StoreKit 2 deliveries into durable, observable
entitlement state — and what that model asks of your handler and your UI.

## Delivery paths and deduplication

Every purchase converges on one FIFO transaction processor, whichever path it
arrives by: a direct `Product.PurchaseResult` passed to
``TransactionStore/process(_:)``, a delivery from `Transaction.updates`, or an
unfinished transaction reconciled at startup and on entitlement refreshes.

Each delivery is identified by its exact JWS revision. When the same revision
arrives through several paths — StoreKit delivers launch-time unfinished
transactions through `Transaction.updates` as well — concurrent deliveries
join the in-flight attempt and completed revisions are suppressed. The
suppression cache is process-local and bounded, which is why the handler
contract is at-least-once rather than exactly-once: the handler must stay
idempotent across process launches and cache eviction.

## Reconciliation before publication

Startup and every entitlement refresh query `Transaction.unfinished` and
durably handle each verified delivery — including consumables — before the
entitlement projection is published, so published entitlement state never
runs ahead of the durable ledger for transactions this device still reports
as unfinished. A transaction that was already finished elsewhere — on another
device, or by a previous process — can appear in the projection without a
local handler invocation; while the app is running, purchases completed on
other devices reach the handler through `Transaction.updates`.

When the handler throws, the transaction is not finished and that refresh (or
startup readiness) fails with the handler's error. The failed work is not
retried in a loop; the next refresh, or the next arriving transaction, opens a
new attempt and retries it. Because public operations other than
``TransactionStore/close()`` wait for the startup attempt, a handler that
hangs blocks the store — return or throw promptly and let a later refresh
retry.

## Verification

Snapshots exist only for transactions that StoreKit verified; the handler and
the projection never observe unverified data. An unverified purchase result
passed to ``TransactionStore/process(_:)`` throws a
``StoreTransactionVerificationError`` to that caller and is not reported to
the failure callback. Unverified elements accepted by background monitoring,
reconciliation, or projection-query paths are reported through the failure
callback instead:

- From `Transaction.updates`, with source
  ``StoreTransactionBackgroundFailure/Source/updates``.
- From `Transaction.unfinished` reconciliation, with source
  ``StoreTransactionBackgroundFailure/Source/unfinished``.
- From a current-entitlement query, with source
  ``StoreTransactionBackgroundFailure/Source/currentEntitlementVerification``;
  the element is omitted and the verified remainder still publishes.

## The entitlement projection

``TransactionStore/entitlements`` is `nil` until the first query resolves and
non-`nil` empty when nothing is currently entitled. Its transactions follow
the stable order documented on ``StoreEntitlements/transactions``. StoreKit
itself excludes refunded and revoked transactions from current entitlements;
the store additionally excludes transactions superseded by a subscription
upgrade from ``TransactionStore/activeEntitlements`` while keeping them in the
complete snapshot.

The projection refreshes at startup, after each processed transaction, on
subscription status changes, and on explicit
``TransactionStore/refreshEntitlements()`` or
``TransactionStore/restorePurchases()`` calls.

Two subscription nuances live outside this projection. A subscription in a
billing grace period stays entitled while its snapshot's `expirationDate` is
already past, so render renewal and billing state from
`Product.SubscriptionInfo.Status` rather than from dates. And entitlement
identifiers map 1:1 to product identifiers, so gate access on the tier set or
on `StoreTransactionSnapshot.subscriptionGroupID` when any tier of a group
grants the same access.

## Failure reporting and readiness

Failure delivery and readiness state are related but separate contracts.
Public operations deliver terminal errors to their attached callers by
throwing. Background-owned physical work reports a failure once through the
failure callback as a ``StoreTransactionBackgroundFailure``. This includes
background deliveries, unfinished and current-entitlement verification, and
direct operations whose every waiting caller cancelled.

Some public operations contain child work whose physical attempt may already
be owned by another producer. A failed `Transaction.unfinished`
reconciliation attempt both fails the enclosing startup or refresh and is
reported once by that attempt's reporting owner. Its source is
``StoreTransactionBackgroundFailure/Source/unfinished`` when reconciliation
owns the attempt, or the existing owner's source — such as
``StoreTransactionBackgroundFailure/Source/updates`` — when reconciliation
joins in-flight work. The enclosing operation propagates the underlying error
but doesn't report that physical failure a second time.

The initial readiness attempt has no throwing public caller.
``TransactionStore/startupError`` reflects its error for observable UI state.
A failed startup unfinished reconciliation therefore appears both as one
owner-sourced report and as `startupError`; that report isn't necessarily
`.unfinished` when the attempt was already in flight. An entitlement query
failure with no separate reporting owner appears only as `startupError`. A
later successful entitlement refresh — which also retries failed unfinished
work — clears the property; call
``TransactionStore/refreshEntitlements()`` from a retry affordance in the UI.

The failure callback receives admitted failures serially and losslessly with
backpressure. Every reporting path waits for the callback to return, and
``TransactionStore/close()`` drains admitted callbacks. Record or enqueue each
failure promptly instead of waiting indefinitely.

## Lifecycle

Create one store per process. A second store would run its own listeners and
hold independent `finish()` authority over the same transactions, so one
store's handler failure could be masked by the other store finishing first.

``TransactionStore/close()`` stops the producers and drains every accepted
operation and callback; dropping the last reference is not an awaitable
shutdown. Production apps normally retain the store for the process lifetime
and never call it.

The injected callbacks must not call back into the same store, directly or
through an awaited child or detached task: the callback runs on the same
worker the re-entrant operation would wait for, so the call becomes a
dependency cycle. Propagated-context reentrancy is rejected with
``StoreTransactionError/reentrantOperation(operation:)``; a detached task
escapes that guard but still forms the cycle.
