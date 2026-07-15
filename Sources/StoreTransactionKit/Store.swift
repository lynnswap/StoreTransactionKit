import Foundation
import Observation
import StoreKit

/// An observable, process-owned StoreKit store.
///
/// Create one store in the application's process composition root. The store
/// starts transaction monitoring during initialization and publishes complete
/// current-entitlement snapshots on the main actor.
///
/// `EntitlementID` is an app-defined, string-backed identifier. Values whose
/// raw values match a current StoreKit entitlement appear in
/// ``activeEntitlements``. The complete verified projection remains available
/// through ``entitlements`` so identifiers outside that app-defined type are
/// never hidden.
@MainActor
@Observable
public final class Store<EntitlementID>
where
    EntitlementID: RawRepresentable & Hashable & Sendable,
    EntitlementID.RawValue == String
{
    /// The latest complete current-entitlement projection.
    ///
    /// The value is `nil` until the first entitlement query succeeds. An empty
    /// projection is non-`nil` and means StoreKit reported no current
    /// entitlements.
    public private(set) var entitlements: StoreEntitlements?

    /// App-defined identifiers represented by the latest current entitlements.
    public private(set) var activeEntitlements: Set<EntitlementID> = []

    /// The error from the initial entitlement query when startup did not reach
    /// readiness.
    ///
    /// Transaction monitoring remains active after a recoverable startup query
    /// failure. A later successful entitlement refresh clears this value.
    public private(set) var startupError: (any Error)?

    @ObservationIgnored private let sessionID: UUID
    @ObservationIgnored private let transactionSession: StoreTransactionSession
    @ObservationIgnored private let startupCompletion: ProcessingReceipt<Void>
    @ObservationIgnored private var startupTask: Task<Void, Never>?

    /// Creates and starts an observable StoreKit store.
    ///
    /// - Parameters:
    ///   - handleTransaction: Applies the durable business effect for a verified
    ///     transaction. The handler must be idempotent because StoreKit delivery
    ///     is at least once. StoreTransactionKit calls `finish()` only after the
    ///     closure returns successfully.
    ///   - reportFailure: Receives failures from process-owned transaction work
    ///     that has no attached public caller.
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
        let owner = StoreOwner<EntitlementID>()
        let sessionID = UUID()
        let startupCompletion = ProcessingReceipt<Void>()
        let transactionSession = StoreTransactionSession(
            sessionID: sessionID,
            source: source,
            handleTransaction: handleTransaction,
            entitlementsDidChange: { entitlements in
                await owner.apply(entitlements)
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
                _ = try await transactionSession.start()
            } catch is CancellationError {
                // Explicit close cancels only this readiness waiter. The
                // session's close operation owns draining accepted work.
            } catch {
                guard !Task.isCancelled else { return }
                self?.startupError = error
            }
        }
    }

    /// Processes a direct result from custom purchase UI.
    ///
    /// StoreKit views deliver successful purchases through
    /// ``StoreKit/Transaction/updates`` by default and don't need to call this
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
    /// - Returns: The complete verified entitlement projection.
    @discardableResult
    public func refreshEntitlements() async throws -> StoreEntitlements {
        try await waitForStartupAttempt(operation: .currentEntitlements)
        return try await transactionSession.currentEntitlements()
    }

    /// Returns verified transaction history for a product in newest-first order.
    public func history(
        for productID: Product.ID
    ) async throws -> [StoreTransactionSnapshot] {
        try await waitForStartupAttempt(operation: .history)
        return try await transactionSession.history(for: productID)
    }

    /// Synchronizes App Store purchases after an explicit user restore action.
    ///
    /// This method can present authentication UI. It refreshes observable
    /// entitlement state before returning.
    @discardableResult
    public func restorePurchases() async throws -> StoreEntitlements {
        try await waitForStartupAttempt(operation: .restorePurchases)
        return try await transactionSession.restorePurchases()
    }

    /// Stops transaction producers and drains every accepted operation.
    ///
    /// Production apps normally retain the store for process lifetime. Call
    /// this method from controlled shutdown and test lifecycles.
    public func close() async throws {
        try rejectReentrancy(operation: .close)
        startupTask?.cancel()
        try await transactionSession.close()
        await startupTask?.value
        startupTask = nil
    }

    fileprivate func apply(_ entitlements: StoreEntitlements) {
        self.entitlements = entitlements
        activeEntitlements = Set(
            entitlements.transactions.compactMap {
                EntitlementID(rawValue: $0.productID)
            })
        startupError = nil
    }

    private func waitForStartupAttempt(
        operation: StoreTransactionOperation
    ) async throws {
        try rejectReentrancy(operation: operation)
        try Task.checkCancellation()
        try await startupCompletion.value()
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

@MainActor
private final class StoreOwner<EntitlementID>: Sendable
where
    EntitlementID: RawRepresentable & Hashable & Sendable,
    EntitlementID.RawValue == String
{
    weak var store: Store<EntitlementID>?

    func apply(_ entitlements: StoreEntitlements) {
        store?.apply(entitlements)
    }
}
