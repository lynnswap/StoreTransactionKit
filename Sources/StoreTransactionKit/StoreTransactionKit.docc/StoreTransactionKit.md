# ``StoreTransactionKit``

Own StoreKit 2 transaction monitoring at application lifetime and finish each
verified transaction only after its durable business effect succeeds.

## Overview

StoreKit can deliver a purchase as a direct `Product.PurchaseResult`, through
`Transaction.updates`, or as unfinished work on a later launch.
``TransactionStore`` normalizes these paths into one verified, FIFO transaction
processor and publishes observable current-entitlement state.

Startup and entitlement refreshes reconcile every verified transaction still
reported by `Transaction.unfinished`, including consumables, before publishing
entitlement state. A durable handler failure fails readiness or the refresh and
leaves that transaction available for a later retry. Unverified unfinished
deliveries are reported through ``StoreTransactionBackgroundFailure/Source/unfinished``.

Create one store in the application composition root. Supply an idempotent
transaction handler that commits the app's business effect before returning.
The app defines a string-backed entitlement identifier type;
``TransactionStore/activeEntitlements`` then exposes an optional typed set
derived from StoreKit's verified current entitlements. `nil` means the initial
entitlement query remains unresolved; an empty set means the query completed
with no matching entitlement. Transactions superseded by a subscription upgrade
remain in the complete snapshot but don't appear in the typed active set. Pass
direct results from custom purchase UI into ``TransactionStore/process(_:)``.

The framework owns StoreKit verification, process-local exact-revision
coalescing, `finish()`, entitlement refresh, history ordering, restore
synchronization, background failure delivery, and explicit shutdown. The app
continues to own persistence, server communication, access presentation, and
the concrete purchase scene or window. It also owns raw
`Product.SubscriptionInfo.Status` interpretation for renewal, grace-period,
and billing-retry UI, and `PurchaseIntent.intents` handling for purchases that
begin outside the app.

> Important: StoreTransactionKit exposes an at-least-once handler-delivery
> contract. Make the injected transaction handler durably idempotent using
> transaction identity and the business event it applies. Purchase and
> revocation revisions are distinct business events. Do not call StoreKit
> `finish()` or call back into the same store from the handler.

## Topics

### Creating a store

- ``TransactionStore``
- ``StoreEntitlements``

### Processing purchases

- ``StorePurchaseOutcome``
- ``StoreTransactionSnapshot``

### Diagnosing lifecycle and background work

- ``StoreTransactionError``
- ``StoreTransactionVerificationError``
- ``StoreTransactionBackgroundFailure``
- ``StoreTransactionOperation``
