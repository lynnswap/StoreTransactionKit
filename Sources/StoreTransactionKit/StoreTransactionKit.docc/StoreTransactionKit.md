# ``StoreTransactionKit``

Centralize verified transaction handling, `Transaction.finish()` authority,
and observable subscription access in one process-owned store.

## Overview

StoreKit can deliver the same purchase through a direct
`Product.PurchaseResult`, `Transaction.updates`, and unfinished-transaction
reconciliation. ``TransactionStore`` joins those paths by exact transaction
revision and publishes raw and app-defined entitlement state together on the
main actor.

Define one ``AutoRenewableSubscriptionCatalog`` from the Product IDs in an App
Store Connect subscription group. Several products, such as monthly and yearly
durations, may grant the same app entitlement. Create one live store at the
application composition root and inject that instance into feature code.

Use ``TransactionStore/isEntitled(to:)`` for feature gating. When UI needs to
explain unavailable access, inspect ``TransactionStore/entitlementStatus`` to
distinguish the initial load, failure, a ready empty set, and an app-supplied
override.

The optional ``TransactionStoreDelegate`` owns only app-specific durable
effects and background-failure reactions. Without a delegate, the default
policy finishes catalog-declared and upgraded same-group auto-renewable
subscriptions. StoreTransactionKit still verifies deliveries, reconciles
unfinished work, validates catalog metadata, orders history, restores
purchases, reports background failures, and drains admitted work during
explicit shutdown.

A non-upgraded product in the managed group that this binary doesn't recognize
remains in the raw projection and doesn't invalidate entitlement readiness. The
optional ``UnrecognizedSubscriptionDelegate`` can leave an unfinished delivery
unfinished, finish it without a typed grant, or map its exact revision to a
known app entitlement.

Start with <doc:DefiningSubscriptionAccess>, then read
<doc:UnderstandingTransactionHandling> before adding an app-owned transaction
effect. <doc:TestingSubscriptionAccess> shows StoreKit-free ViewModel tests
that use the production store data flow.

## Topics

### Essentials

- <doc:DefiningSubscriptionAccess>
- <doc:UnderstandingTransactionHandling>
- <doc:TestingSubscriptionAccess>

### Declaring subscriptions

- ``AutoRenewableSubscriptionCatalog``
- ``AutoRenewableSubscriptionGroup``
- ``SubscriptionGroupID``
- ``StoreSubscription``
- ``StoreSubscriptionsBuilder``

### Reading entitlement state

- ``TransactionStore``
- ``EntitlementStatus``
- ``StoreEntitlements``

### Processing transactions

- ``TransactionStoreDelegate``
- ``StoreTransactionHandlingPolicy``
- ``UnrecognizedSubscriptionDelegate``
- ``UnrecognizedSubscriptionPolicy``
- ``StorePurchaseOutcome``
- ``StoreTransactionSnapshot``

### Failures and lifecycle

- ``StoreTransactionError``
- ``StoreTransactionVerificationError``
- ``StoreTransactionBackgroundFailure``
- ``StoreTransactionOperation``
