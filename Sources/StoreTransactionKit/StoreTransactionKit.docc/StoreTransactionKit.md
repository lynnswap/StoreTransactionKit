# ``StoreTransactionKit``

Own StoreKit 2 transaction monitoring at application lifetime and finish each
verified transaction only after its durable business effect succeeds.

## Overview

StoreKit can deliver a purchase as a direct ``StoreKit/Product/PurchaseResult``,
through ``StoreKit/Transaction/updates``, or as unfinished work on a later
launch. ``Store`` normalizes these paths into one verified, FIFO transaction
processor and publishes observable current-entitlement state.

Create one store in the application composition root. Supply an idempotent
transaction handler that commits the app's business effect before returning.
The app defines a string-backed entitlement identifier type;
``Store/activeEntitlements`` then exposes an optional typed set derived from
StoreKit's verified current entitlements. `nil` means the initial entitlement
query remains unresolved; an empty set means the query completed with no
matching entitlement. Pass direct results from custom purchase UI into
``Store/process(_:)``.

The framework owns StoreKit verification, process-local exact-revision
coalescing, `finish()`, entitlement refresh, history ordering, restore
synchronization, background failure delivery, and explicit shutdown. The app
continues to own persistence, server communication, access presentation, and
the concrete purchase scene or window.

> Important: StoreKit delivery is at least once. Make the injected transaction
> handler durably idempotent using transaction identity and the business event
> it applies. Do not call StoreKit `finish()` from the handler.

## Topics

### Creating a store

- ``Store``
- ``StoreEntitlements``

### Processing purchases

- ``StorePurchaseOutcome``
- ``StoreTransactionSnapshot``

### Diagnosing lifecycle and background work

- ``StoreTransactionError``
- ``StoreTransactionBackgroundFailure``
- ``StoreTransactionOperation``
