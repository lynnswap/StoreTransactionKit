/// The action StoreTransactionKit takes for a valid, undeclared subscription
/// in the catalog's subscription group.
public enum UnrecognizedSubscriptionPolicy<Entitlement>: Sendable, Hashable
where Entitlement: Hashable & Sendable {
    /// Leaves the transaction unfinished and grants no typed entitlement.
    case leaveUnfinished

    /// Finishes the transaction without granting a typed entitlement.
    case finish

    /// Finishes the transaction and projects it as a known app entitlement.
    case treatAs(Entitlement)
}

/// Resolves valid subscriptions that this binary does not declare in its catalog.
///
/// StoreTransactionKit invokes this delegate only for a non-upgraded
/// auto-renewable subscription whose group matches the catalog and whose Product
/// ID is undeclared. Decisions are serialized and reused for the exact
/// transaction revision. Do not call an admission-bearing operation on the same
/// ``TransactionStore`` from this method.
public protocol UnrecognizedSubscriptionDelegate<Entitlement>:
    AnyObject,
    Sendable
{
    associatedtype Entitlement: Hashable & Sendable

    /// Chooses how to handle and project an undeclared subscription.
    ///
    /// Throwing leaves an unfinished transaction unfinished and makes the
    /// current entitlement refresh fail transiently. A later independent
    /// attempt may retry the decision.
    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> UnrecognizedSubscriptionPolicy<Entitlement>
}
