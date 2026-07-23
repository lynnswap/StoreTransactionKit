/// The action StoreTransactionKit takes after classifying a verified transaction.
public enum StoreTransactionHandlingPolicy: Sendable, Hashable {
    /// Finishes a catalog-declared transaction without an app-owned business
    /// effect.
    ///
    /// StoreTransactionKit rejects this policy for an out-of-group transaction.
    case automatic

    /// Finishes a transaction after the app has durably applied its business effect.
    ///
    /// Use this policy for an unmanaged product only after the app has committed
    /// its idempotent business effect.
    case finish
}

/// Receives transaction decisions and background failure notifications.
///
/// The delegate is optional because both requirements have default
/// implementations. Policy decisions and failure notifications are each
/// serialized, but the two streams may overlap. Valid undeclared subscriptions
/// in the catalog's group are resolved separately by
/// ``UnrecognizedSubscriptionDelegate``.
public protocol TransactionStoreDelegate: AnyObject, Sendable {
    /// Chooses how to handle a verified transaction.
    ///
    /// StoreTransactionKit invokes decisions serially after catalog
    /// classification for declared and out-of-group transactions. Throwing
    /// prevents the transaction from being finished and prevents its causal
    /// entitlement refresh. A later independent StoreKit delivery may retry the
    /// exact revision.
    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy

    /// Notifies the delegate of a failure owned by background work.
    ///
    /// This notification cannot alter the completed operation or request a
    /// retry. Delivery is serialized and applies backpressure. When a failure
    /// changes observable entitlement state, that state is committed before
    /// this method begins.
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
