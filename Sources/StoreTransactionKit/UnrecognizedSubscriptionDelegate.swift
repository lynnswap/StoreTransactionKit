/// The action StoreTransactionKit takes for a valid, non-upgraded undeclared
/// subscription in the catalog's subscription group.
public enum UnrecognizedSubscriptionPolicy<Entitlement>: Sendable, Hashable
where Entitlement: Hashable & Sendable {
    /// Grants no typed entitlement and leaves an unfinished delivery unfinished.
    case leaveUnfinished

    /// Grants no typed entitlement and finishes an unfinished delivery.
    case finish

    /// Projects the revision as a known app entitlement and finishes an
    /// unfinished delivery.
    case treatAs(Entitlement)
}

/// Resolves valid subscriptions that this binary does not declare in its catalog.
///
/// StoreTransactionKit invokes this delegate only for a non-upgraded
/// auto-renewable subscription whose group matches the catalog and whose Product
/// ID is undeclared. Decisions are serialized. A successful decision is reused
/// for the exact transaction revision until the store closes. Do not call an
/// admission-bearing operation on the same ``TransactionStore`` from this
/// method.
public protocol UnrecognizedSubscriptionDelegate<Entitlement>:
    AnyObject,
    Sendable
{
    associatedtype Entitlement: Hashable & Sendable

    /// Chooses how to handle and project an undeclared subscription.
    ///
    /// Throwing isn't cached. It leaves an unfinished delivery unfinished,
    /// makes the current entitlement refresh fail transiently, and allows a
    /// later independent attempt to ask again.
    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> UnrecognizedSubscriptionPolicy<Entitlement>
}
