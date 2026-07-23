/// The action StoreTransactionKit takes after classifying a verified transaction.
public enum StoreTransactionHandlingPolicy: Sendable, Hashable {
    /// Finishes a catalog-managed transaction without an app-owned business effect.
    ///
    /// StoreTransactionKit rejects this policy for a transaction outside the
    /// managed subscription catalog.
    case automatic

    /// Finishes a transaction after the app has durably applied its business effect.
    case finish
}

/// Receives transaction decisions and background failure notifications.
///
/// The delegate is optional because both requirements have default
/// implementations. Conforming types may use an actor or provide their own
/// synchronization; the protocol does not prescribe an actor.
public protocol TransactionStoreDelegate: AnyObject, Sendable {
    /// Chooses how to handle a verified transaction.
    ///
    /// StoreTransactionKit invokes decisions serially. Throwing prevents the
    /// transaction from being finished and prevents its causal entitlement
    /// refresh.
    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy

    /// Notifies the delegate of a failure owned by background work.
    ///
    /// This notification cannot alter the completed operation or request a
    /// retry. When a failure changes observable entitlement state, that state
    /// is committed before this method begins.
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
