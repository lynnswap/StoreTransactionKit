import Foundation
import Observation
import StoreKit

/// An observable, process-owned StoreKit store.
///
/// Create one store in the application's process composition root. The store
/// starts transaction monitoring during initialization and publishes complete
/// current-entitlement snapshots on the main actor.
/// Public operations other than ``close()`` wait for the startup attempt,
/// including durable handling of startup unfinished transactions, to complete.
///
/// `EntitlementID` is an app-defined, string-backed identifier. Values whose
/// raw values match a current StoreKit entitlement appear in
/// ``activeEntitlements``. The complete verified projection remains available
/// through ``entitlements`` so identifiers outside that app-defined type are
/// never hidden.
///
/// <doc:UnderstandingTransactionHandling> describes the delivery,
/// reconciliation, and failure-reporting model behind this type.
@MainActor
@Observable
public final class TransactionStore<EntitlementID>
where
    EntitlementID: RawRepresentable & Hashable & Sendable,
    EntitlementID.RawValue == String
{
    /// The latest verified current-entitlement projection.
    ///
    /// The value is `nil` until the first entitlement query succeeds. An empty
    /// projection is non-`nil` and means StoreKit reported no current
    /// entitlements. Elements that StoreKit can't verify are omitted and
    /// reported through the failure callback.
    public private(set) var entitlements: StoreEntitlements?

    /// App-defined identifiers represented by the latest active entitlements.
    ///
    /// The value is `nil` until the first entitlement query succeeds. An empty
    /// set is non-`nil` and means none of the app-defined identifiers is
    /// currently entitled. Transactions superseded by a subscription upgrade
    /// remain available through ``entitlements`` but don't appear in this set.
    public var activeEntitlements: Set<EntitlementID>? {
        entitlements.map { entitlements in
            Set(
                entitlements.transactions.compactMap {
                    guard !$0.isUpgraded else { return nil }
                    return EntitlementID(rawValue: $0.productID)
                })
        }
    }

    /// The error from the initial readiness attempt.
    ///
    /// Startup includes durable handling of every verified transaction still
    /// reported by `Transaction.unfinished`. Transaction monitoring remains
    /// active after a recoverable startup failure. A later successful
    /// entitlement refresh retries unfinished work and clears this value.
    public private(set) var startupError: (any Error)?

    @ObservationIgnored private let sessionID: UUID
    @ObservationIgnored private let transactionSession: StoreTransactionSession
    @ObservationIgnored private let startupCompletion: ProcessingReceipt<Void>
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var startupOrdering = TransactionStoreStartupOrdering()

    /// Creates and starts an observable StoreKit store.
    ///
    /// - Parameters:
    ///   - handleTransaction: Applies the durable business effect for a verified
    ///     transaction. StoreTransactionKit exposes an at-least-once
    ///     handler-delivery contract, so the handler must be idempotent.
    ///     StoreTransactionKit calls `finish()` only after the closure returns
    ///     successfully. The handler must not call back into the same store,
    ///     directly or through an awaited child task, because doing so creates a
    ///     dependency cycle with the operation being handled.
    ///   - reportFailure: Receives failures from process-owned transaction work
    ///     that has no attached public caller. This callback must not call back
    ///     into the same store, directly or through an awaited child task.
    public convenience init(
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        self.init(
            source: .live,
            handleTransaction: handleTransaction,
            reportFailure: reportFailure
        )
    }

    package init(
        source: StoreTransactionSource,
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        let owner = TransactionStoreOwner<EntitlementID>()
        let sessionID = UUID()
        let startupCompletion = ProcessingReceipt<Void>()
        let transactionSession = StoreTransactionSession(
            sessionID: sessionID,
            source: source,
            handleTransaction: handleTransaction,
            entitlementsDidChange: { _ in },
            entitlementRefreshDidSucceed: { success in
                await owner.apply(success)
            },
            reportFailure: reportFailure
        )
        self.sessionID = sessionID
        self.transactionSession = transactionSession
        self.startupCompletion = startupCompletion
        owner.store = self

        startupTask = Task { [weak self, transactionSession] in
            defer { startupCompletion.succeed(()) }
            do {
                _ = try await transactionSession.startForTransactionStore()
            } catch let failure as StoreTransactionReadinessFailure {
                guard !Task.isCancelled else { return }
                self?.applyStartupFailure(
                    token: failure.refreshToken,
                    error: failure.underlyingError
                )
            } catch {
                // Explicit close cancels only this readiness waiter. The
                // session's close operation owns draining accepted work.
                guard !Task.isCancelled else { return }
                self?.startupOrdering.recordUnsequencedFailure()
                self?.startupError = error
            }
        }
    }

    /// Processes a direct result from custom purchase UI.
    ///
    /// StoreKit views deliver successful purchases through
    /// `Transaction.updates` by default and don't need to call this
    /// method. Use it for a result returned directly by a `Product` purchase
    /// API or by a custom StoreKit view completion action.
    public func process(
        _ result: Product.PurchaseResult
    ) async throws -> StorePurchaseOutcome {
        try await waitForStartupAttempt(operation: .processPurchase)
        return try await transactionSession.process(result)
    }

    /// Refreshes current entitlements and updates observable store state.
    ///
    /// Before publishing the result, the store durably handles every verified
    /// transaction currently reported by `Transaction.unfinished`, including
    /// consumables. A handler failure leaves the transaction unfinished, fails
    /// this refresh, and allows a later refresh to retry it.
    ///
    /// - Returns: The complete verified entitlement projection.
    @discardableResult
    public func refreshEntitlements() async throws -> StoreEntitlements {
        try await waitForStartupAttempt(operation: .currentEntitlements)
        return try await transactionSession.currentEntitlements()
    }

    /// Returns verified transaction history for a product in newest-first order.
    ///
    /// StoreKit omits finished consumables unless the app enables
    /// `SKIncludeConsumableInAppPurchaseHistory` in its information property
    /// list. Revoked and refunded transactions remain in the returned history.
    /// Results are ordered by purchase date, signed date, and transaction
    /// identifier descending, then exact JWS UTF-8 bytes ascending.
    public func history(
        for productID: Product.ID
    ) async throws -> [StoreTransactionSnapshot] {
        try await waitForStartupAttempt(operation: .history)
        return try await transactionSession.history(for: productID)
    }

    /// Synchronizes App Store purchases after an explicit user restore action.
    ///
    /// This method can present authentication UI. It refreshes observable
    /// entitlement state before returning. StoreKit may throw
    /// `StoreKitError.userCancelled` when the user dismisses
    /// authentication; treat that as a normal user outcome rather than a
    /// diagnostic failure.
    @discardableResult
    public func restorePurchases() async throws -> StoreEntitlements {
        try await waitForStartupAttempt(operation: .restorePurchases)
        return try await transactionSession.restorePurchases()
    }

    /// Stops transaction producers and drains every accepted operation.
    ///
    /// Production apps normally retain the store for process lifetime. Call
    /// this method from controlled shutdown and test lifecycles.
    ///
    /// - Throws: ``StoreTransactionError/reentrantOperation(operation:)`` when
    ///   an injected callback attempts to close the store that is executing it.
    public func close() async throws {
        try rejectReentrancy(operation: .close)
        startupTask?.cancel()
        try await transactionSession.close()
        await startupTask?.value
        startupTask = nil
    }

    fileprivate func apply(_ success: EntitlementRefreshSuccess) {
        entitlements = success.entitlements
        if startupOrdering.recordSuccess(token: success.token) {
            startupError = nil
        }
    }

    private func applyStartupFailure(
        token: UInt64,
        error: any Error
    ) {
        if startupOrdering.recordFailure(token: token) {
            startupError = error
        }
    }

    private func waitForStartupAttempt(
        operation: StoreTransactionOperation
    ) async throws {
        try rejectReentrancy(operation: operation)
        try Task.checkCancellation()
        do {
            try await startupCompletion.value()
        } catch is ProcessingReceiptWaiterCancellation {
            throw CancellationError()
        }
    }

    private func rejectReentrancy(
        operation: StoreTransactionOperation
    ) throws {
        if let invocation = StoreTransactionCallbackContext.current,
            invocation.sessionID == sessionID
        {
            throw StoreTransactionError.reentrantOperation(operation: operation)
        }
    }

    package func waitForStartup() async {
        _ = try? await startupCompletion.terminalValue()
    }

    isolated deinit {
        startupTask?.cancel()
    }
}

package struct TransactionStoreStartupOrdering: Sendable {
    private var latestSuccessfulToken: UInt64 = 0
    private var failureToken: UInt64?

    package mutating func recordSuccess(token: UInt64) -> Bool {
        precondition(token > latestSuccessfulToken)
        latestSuccessfulToken = token
        guard let failureToken, token > failureToken else { return false }
        self.failureToken = nil
        return true
    }

    package mutating func recordFailure(token: UInt64) -> Bool {
        guard latestSuccessfulToken < token else { return false }
        failureToken = token
        return true
    }

    package mutating func recordUnsequencedFailure() {
        failureToken = latestSuccessfulToken
    }
}

@MainActor
private final class TransactionStoreOwner<EntitlementID>: Sendable
where
    EntitlementID: RawRepresentable & Hashable & Sendable,
    EntitlementID.RawValue == String
{
    weak var store: TransactionStore<EntitlementID>?

    func apply(_ success: EntitlementRefreshSuccess) {
        store?.apply(success)
    }
}
