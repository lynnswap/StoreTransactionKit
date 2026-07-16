import Foundation
import StoreKit

/// The package-owned StoreKit 2 transaction and entitlement session.
///
/// Create exactly one session in the application's process composition root and
/// call ``start()`` as early as the app's durable dependencies are available.
/// The session monitors StoreKit updates and startup unfinished transactions;
/// presentation of purchase UI remains the application's responsibility.
///
/// Explicitly call ``close()`` from controlled shutdown and test lifecycles.
/// Dropping the last reference is not an awaitable shutdown mechanism.
package actor StoreTransactionSession {
    private struct Configuration: Sendable {
        let source: StoreTransactionSource
        let handleTransaction: @Sendable (StoreTransactionSnapshot) async throws -> Void
        let entitlementsDidChange: @Sendable (StoreEntitlements) async -> Void
        let reportFailure: @Sendable (StoreTransactionBackgroundFailure) async -> Void
    }

    private enum State: Sendable {
        case initialized(Configuration)
        case running(StoreTransactionRuntime)
        case closing(Task<Void, Never>)
        case closed
    }

    private let sessionID: UUID
    private var state: State

    /// Creates a StoreKit transaction session.
    ///
    /// - Parameters:
    ///   - handleTransaction: Applies the durable business effect for a verified
    ///     transaction. StoreTransactionKit exposes an at-least-once
    ///     handler-delivery contract, so the handler must be idempotent.
    ///     StoreTransactionKit calls `finish()` only after this closure returns
    ///     successfully.
    ///   - entitlementsDidChange: Receives complete, ordered entitlement
    ///     snapshots when the current entitlement content changes.
    ///   - reportFailure: Receives failures from process-owned work that has no
    ///     attached public caller. The callback is lossless and backpressured.
    ///
    /// None of the callbacks may call back into the same session.
    package init(
        sessionID: UUID = UUID(),
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        entitlementsDidChange:
            @escaping @Sendable (StoreEntitlements) async -> Void = { _ in },
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        self.sessionID = sessionID
        self.state = .initialized(
            Configuration(
                source: .live,
                handleTransaction: handleTransaction,
                entitlementsDidChange: entitlementsDidChange,
                reportFailure: reportFailure
            ))
    }

    package init(
        sessionID: UUID = UUID(),
        source: StoreTransactionSource,
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        entitlementsDidChange:
            @escaping @Sendable (StoreEntitlements) async -> Void = { _ in },
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        self.sessionID = sessionID
        self.state = .initialized(
            Configuration(
                source: source,
                handleTransaction: handleTransaction,
                entitlementsDidChange: entitlementsDidChange,
                reportFailure: reportFailure
            ))
    }

    /// Starts transaction monitoring, reconciles unfinished work, and publishes initial entitlements.
    ///
    /// All StoreKit producer tasks are retained before this method first
    /// suspends. The method returns only after the startup unfinished sequence,
    /// the initial entitlement query, and any initial entitlement callback have
    /// completed.
    ///
    /// If the waiting caller cancels after startup begins, the process-owned
    /// session remains running. Its lifecycle owner must call ``close()``.
    ///
    /// - Returns: The initial entitlement readiness value.
    /// - Throws: A lifecycle or callback reentrancy error, an entitlement query
    ///   error, or `CancellationError` when the attached waiter cancels.
    package func start() async throws -> StoreTransactionReadiness {
        guard case .initialized(let configuration) = state else {
            switch state {
            case .running: throw StoreTransactionLifecycleError.alreadyStarted
            case .closing: throw StoreTransactionError.closing
            case .closed: throw StoreTransactionError.closed
            case .initialized: preconditionFailure()
            }
        }

        let runtime = StoreTransactionRuntime(
            sessionID: sessionID,
            source: configuration.source,
            handleTransaction: configuration.handleTransaction,
            entitlementsDidChange: configuration.entitlementsDidChange,
            reportFailure: configuration.reportFailure
        )
        state = .running(runtime)

        let readiness = try await runtime.readiness()
        guard case .running(let activeRuntime) = state,
            activeRuntime === runtime
        else {
            throw StoreTransactionError.closing
        }
        return readiness
    }

    /// Processes the result of purchase UI presented by the application.
    ///
    /// A verified success enters the same durable FIFO used by updates and
    /// unfinished transactions. Pending and user-cancelled results are returned
    /// as values and never reported as failures.
    ///
    /// - Parameter result: The purchase result returned by StoreKit.
    /// - Returns: The semantic outcome after any required durable handling,
    ///   finish, and entitlement refresh.
    /// - Throws: Verification, durable handler, entitlement refresh, lifecycle,
    ///   callback reentrancy, or caller cancellation errors.
    package func process(
        _ result: Product.PurchaseResult
    ) async throws -> StorePurchaseOutcome {
        let runtime = try runningRuntime(operation: .processPurchase)
        guard let leases = runtime.beginOperation() else {
            throw StoreTransactionError.closing
        }
        return try await runtime.process(result, leases: leases)
    }

    /// Refreshes and returns the complete current entitlement projection.
    ///
    /// Concurrent refresh reservations are coalesced only when they precede the
    /// same physical query cutoff. A changed result is returned after its ordered
    /// callback completes.
    ///
    /// - Returns: The current entitlement publication.
    /// - Throws: A StoreKit verification or query error, a lifecycle or callback
    ///   reentrancy error, or `CancellationError` for an abandoned waiter.
    package func currentEntitlements() async throws -> StoreEntitlements {
        let runtime = try runningRuntime(operation: .currentEntitlements)
        guard let leases = runtime.beginOperation() else {
            throw StoreTransactionError.closing
        }
        return try await runtime.currentEntitlements(leases: leases)
    }

    /// Returns verified transaction history for a product in newest-first order.
    ///
    /// The query is all-or-nothing: one unverified element fails the complete
    /// result. Revoked and refunded transactions remain in this audit projection.
    ///
    /// - Parameter productID: The StoreKit product identifier to query.
    /// - Returns: Verified snapshots ordered by purchase date, signed date, and
    ///   transaction identifier descending, then exact JWS UTF-8 bytes
    ///   ascending.
    /// - Throws: A StoreKit verification or query error, a lifecycle or callback
    ///   reentrancy error, or `CancellationError` for an abandoned waiter.
    package func history(
        for productID: Product.ID
    ) async throws -> [StoreTransactionSnapshot] {
        let runtime = try runningRuntime(operation: .history)
        guard let leases = runtime.beginOperation() else {
            throw StoreTransactionError.closing
        }
        return try await runtime.history(for: productID, leases: leases)
    }

    /// Explicitly synchronizes App Store purchases and refreshes entitlements.
    ///
    /// Call this method only from a user-initiated restore action because
    /// ``StoreKit/AppStore/sync()`` can present authentication UI. Concurrent
    /// callers share one synchronization operation.
    ///
    /// - Returns: The entitlement publication from a query reserved after sync succeeds.
    /// - Throws: A synchronization, verification, query, lifecycle, callback
    ///   reentrancy, or caller cancellation error. StoreKit may throw
    ///   ``StoreKit/StoreKitError/userCancelled`` when the user dismisses
    ///   authentication; callers should treat that as a normal user outcome.
    package func restorePurchases() async throws -> StoreEntitlements {
        let runtime = try runningRuntime(operation: .restorePurchases)
        guard let leases = runtime.beginOperation() else {
            throw StoreTransactionError.closing
        }
        return try await runtime.restorePurchases(leases: leases)
    }

    /// Stops producers and drains every operation and callback accepted before closing.
    ///
    /// The first caller creates one shared noncancellable close completion;
    /// concurrent callers join it. Calling this method before ``start()`` closes
    /// the session without acquiring StoreKit resources. Calling it again after
    /// closure succeeds without effect.
    ///
    /// - Throws: A callback reentrancy error when one of this session's injected
    ///   callbacks attempts to close the session that is executing it.
    package func close() async throws {
        try rejectReentrancy(operation: .close)
        switch state {
        case .initialized:
            state = .closed
        case .running(let runtime):
            let closeTask = Task {
                await runtime.close()
            }
            state = .closing(closeTask)
            await closeTask.value
            state = .closed
        case .closing(let closeTask):
            await closeTask.value
            state = .closed
        case .closed:
            return
        }
    }

    private func runningRuntime(
        operation: StoreTransactionOperation
    ) throws -> StoreTransactionRuntime {
        try rejectReentrancy(operation: operation)
        switch state {
        case .initialized:
            throw StoreTransactionLifecycleError.notStarted
        case .running(let runtime):
            return runtime
        case .closing:
            throw StoreTransactionError.closing
        case .closed:
            throw StoreTransactionError.closed
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

    isolated deinit {
        switch state {
        case .running(let runtime):
            runtime.cancelSynchronously()
        case .closing(let closeTask):
            closeTask.cancel()
        case .initialized, .closed:
            break
        }
    }
}
