# ``StoreTransactionKit``

Own StoreKit 2 transaction monitoring at application lifetime and finish each
verified transaction only after its durable business effect succeeds.

## Overview

StoreKit can deliver a purchase as a direct `Product.PurchaseResult`, through
`Transaction.updates`, or as unfinished work on a later launch.
``TransactionStore`` normalizes these paths into one verified, FIFO transaction
processor and publishes observable current-entitlement state. It supports
iOS and Mac Catalyst 18.4 and later, macOS 15.4 and later, tvOS 18.4 and
later, watchOS 11.4 and later, and visionOS 2.4 and later.

Create one store in the application composition root and retain it for the
process lifetime; call ``TransactionStore/close()`` only from controlled
shutdown and test lifecycles. Supply an idempotent transaction handler that
commits the app's business effect before returning. The app defines a
string-backed entitlement identifier type;
``TransactionStore/activeEntitlements`` then exposes an optional typed set
derived from StoreKit's verified current entitlements. Pass direct results
from custom purchase UI into ``TransactionStore/process(_:)``.

<doc:UnderstandingTransactionHandling> describes the full model: delivery
paths and deduplication, unfinished-transaction reconciliation before each
entitlement publication, verification-failure reporting, and how the
projection behaves across upgrades, revocations, and grace periods.

The framework owns StoreKit verification, process-local exact-revision
coalescing, `finish()`, entitlement refresh, history ordering, restore
synchronization, background failure delivery, and explicit shutdown. The app
continues to own persistence, server communication, access presentation, the
concrete purchase scene or window, raw `Product.SubscriptionInfo.Status`
interpretation for renewal UI, and, where the API is available,
`PurchaseIntent.intents` handling for purchases that begin outside the app.

> Important: StoreTransactionKit exposes an at-least-once handler-delivery
> contract. Make the injected transaction handler durably idempotent using
> transaction identity and the business event it applies. Purchase and
> revocation revisions are distinct business events. Do not call StoreKit
> `finish()` or call back into the same store from the handler.

## Topics

### Essentials

- <doc:UnderstandingTransactionHandling>

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
