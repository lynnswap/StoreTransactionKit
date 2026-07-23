import Observation
import StoreKit

/// An observable, process-owned StoreKit transaction and entitlement store.
///
/// A live store monitors StoreKit deliveries, owns `Transaction.finish()`
/// authority, and publishes raw and app-defined entitlement state together on
/// the main actor. Create one live instance at the application composition root
/// and retain it for the process lifetime.
@MainActor
@Observable
public final class TransactionStore<Entitlement>
where Entitlement: Hashable & Sendable {
    private enum EntitlementAvailability {
        case loading
        case failed(any Error)
        case ready(
            entitlements: StoreEntitlements,
            activeEntitlements: Set<Entitlement>
        )
        case overridden(activeEntitlements: Set<Entitlement>)
    }

    private enum Backend: Sendable {
        case liveRuntime(
            StoreTransactionRuntime<Entitlement>,
            TransactionStoreLifecycle
        )
        case syntheticRuntime(
            StoreTransactionRuntime<Entitlement>,
            TransactionStoreLifecycle,
            @Sendable (StoreTransactionOperation) -> any Error
        )
        case override
    }

    private struct RuntimeAdmission: Sendable {
        let runtime: StoreTransactionRuntime<Entitlement>
        let leases: FiniteOperationLeases
    }

    /// The availability of the typed entitlement projection.
    ///
    /// Inspect this value when the UI needs to distinguish loading or failure
    /// from a ready empty entitlement set.
    public var entitlementStatus: EntitlementStatus {
        switch availability {
        case .loading:
            .loading
        case .failed(let error):
            .failed(error)
        case .ready:
            .ready
        case .overridden:
            .overridden
        }
    }

    /// The latest complete raw StoreKit entitlement projection.
    ///
    /// This value is non-`nil` only in ``EntitlementStatus/ready``. Override
    /// mode has no synthetic raw StoreKit projection. A ready projection can
    /// include a valid same-group product that this binary doesn't declare.
    public var entitlements: StoreEntitlements? {
        guard case .ready(let entitlements, _) = availability else {
            return nil
        }
        return entitlements
    }

    /// The app-defined entitlements granted by the current catalog projection.
    ///
    /// A non-`nil` empty set authoritatively means that no app entitlement is
    /// active. Declared products use the catalog mapping; an unrecognized
    /// subscription contributes only when its delegate policy uses
    /// ``UnrecognizedSubscriptionPolicy/treatAs(_:)``. The value is `nil` while
    /// loading or when no usable projection is available after failure.
    public var activeEntitlements: Set<Entitlement>? {
        switch availability {
        case .ready(_, let activeEntitlements),
            .overridden(let activeEntitlements):
            activeEntitlements
        case .loading, .failed:
            nil
        }
    }

    @ObservationIgnored private let sessionID: UUID
    @ObservationIgnored private let backend: Backend
    private var availability: EntitlementAvailability

    /// Creates the process's live StoreKit store for an auto-renewable subscription catalog.
    ///
    /// Initialization starts transaction monitoring and the first entitlement
    /// reconciliation. The store strongly retains both delegates until terminal
    /// shutdown. Creating a second live store in the same process before the
    /// first store finishes ``close()`` is a programmer error. Without
    /// `unrecognizedSubscriptionDelegate`, valid non-upgraded undeclared
    /// same-group subscriptions use
    /// ``UnrecognizedSubscriptionPolicy/leaveUnfinished``.
    public convenience init(
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)? = nil,
        unrecognizedSubscriptionDelegate:
            (any UnrecognizedSubscriptionDelegate<Entitlement>)? = nil
    ) {
        let liveLease = LiveTransactionStoreLease.acquire()
        let lifecycle = TransactionStoreLifecycle(liveLease: liveLease)
        self.init(
            source: .live,
            lifecycle: lifecycle,
            backendKind: .live,
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate
        )
    }

    /// Creates a StoreKit-free store with one authoritative entitlement set.
    ///
    /// The sequence is normalized to a set and published immediately with
    /// ``EntitlementStatus/overridden``. This store performs no StoreKit work,
    /// has no raw ``entitlements``, and rejects StoreKit-backed operations.
    public convenience init(
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        overridingEntitlements: some Sequence<Entitlement>
    ) {
        _ = subscriptionCatalog
        self.init(
            sessionID: UUID(),
            availability: .overridden(
                activeEntitlements: Set(overridingEntitlements)
            ),
            backend: .override
        )
    }

    convenience init(
        source: StoreTransactionSource,
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)? = nil,
        unrecognizedSubscriptionDelegate:
            (any UnrecognizedSubscriptionDelegate<Entitlement>)? = nil
    ) {
        self.init(
            source: source,
            lifecycle: TransactionStoreLifecycle(),
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate
        )
    }

    convenience init(
        source: StoreTransactionSource,
        lifecycle: TransactionStoreLifecycle,
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)? = nil,
        unrecognizedSubscriptionDelegate:
            (any UnrecognizedSubscriptionDelegate<Entitlement>)? = nil
    ) {
        self.init(
            source: source,
            lifecycle: lifecycle,
            backendKind: .live,
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate
        )
    }

    package convenience init(
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        syntheticSource: SyntheticStoreTransactionSource,
        delegate: (any TransactionStoreDelegate)? = nil,
        unrecognizedSubscriptionDelegate:
            (any UnrecognizedSubscriptionDelegate<Entitlement>)? = nil,
        unavailableOperationError:
            @escaping @Sendable (StoreTransactionOperation) -> any Error
    ) {
        self.init(
            source: syntheticSource.source,
            lifecycle: TransactionStoreLifecycle(),
            backendKind: .synthetic(unavailableOperationError),
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate
        )
    }

    private enum BackendKind: Sendable {
        case live
        case synthetic(@Sendable (StoreTransactionOperation) -> any Error)
    }

    private convenience init(
        source: StoreTransactionSource,
        lifecycle: TransactionStoreLifecycle,
        backendKind: BackendKind,
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)?,
        unrecognizedSubscriptionDelegate:
            (any UnrecognizedSubscriptionDelegate<Entitlement>)?
    ) {
        let sessionID = UUID()
        let owner = TransactionStoreAvailabilityOwner<Entitlement>()
        let runtime = StoreTransactionRuntime(
            sessionID: sessionID,
            source: source,
            lifecycle: lifecycle,
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate,
            entitlementOutcome: { outcome in
                await owner.apply(outcome)
            }
        )
        let backend: Backend
        switch backendKind {
        case .live:
            backend = .liveRuntime(runtime, lifecycle)
        case .synthetic(let unavailableOperationError):
            backend = .syntheticRuntime(
                runtime,
                lifecycle,
                unavailableOperationError
            )
        }
        self.init(
            sessionID: sessionID,
            availability: .loading,
            backend: backend
        )
        owner.attach(self)
        runtime.start()
    }

    private init(
        sessionID: UUID,
        availability: EntitlementAvailability,
        backend: Backend
    ) {
        self.sessionID = sessionID
        self.availability = availability
        self.backend = backend
    }

    /// Returns whether the exact app-defined entitlement is active.
    ///
    /// This method returns `false` while entitlement state is unavailable.
    public func isEntitled(to entitlement: Entitlement) -> Bool {
        activeEntitlements?.contains(entitlement) == true
    }

    /// Processes a direct result from custom purchase UI.
    ///
    /// A verified purchase returns only after policy selection, the selected
    /// finish or leave action, causal entitlement reconciliation, and main-actor
    /// publication. Pending and user-cancelled results return their corresponding
    /// semantic outcome without transaction processing.
    public func process(
        _ result: Product.PurchaseResult
    ) async throws -> StorePurchaseOutcome {
        let admission = try admit(operation: .processPurchase)
        return try await admission.runtime.process(
            result,
            leases: admission.leases
        )
    }

    func process(
        _ delivery: StoreTransactionDelivery,
        didAdmit: @escaping @Sendable () async -> Void = {}
    ) async throws -> StorePurchaseOutcome {
        let admission = try admit(operation: .processPurchase)
        return try await admission.runtime.process(
            delivery,
            leases: admission.leases,
            didAdmit: didAdmit
        )
    }

    package func processSyntheticDelivery(
        _ delivery: StoreTransactionDelivery,
        didAdmit: @escaping @Sendable () async -> Void = {}
    ) async throws -> StorePurchaseOutcome {
        try rejectReentrancy(operation: .processPurchase)
        guard case .syntheticRuntime(let runtime, let lifecycle, _) = backend else {
            preconditionFailure(
                "Synthetic deliveries require a synthetic TransactionStore."
            )
        }
        let leases = try lifecycle.beginOperation()
        return try await runtime.process(
            delivery,
            leases: leases,
            didAdmit: didAdmit
        )
    }

    package func refreshSyntheticEntitlements<AdmissionResult: Sendable>(
        didAdmit: () throws -> AdmissionResult
    ) async throws -> AdmissionResult {
        try Task.checkCancellation()
        try rejectReentrancy(operation: .refreshEntitlements)
        guard case .syntheticRuntime(let runtime, let lifecycle, _) = backend else {
            preconditionFailure(
                "Synthetic entitlement mutation requires a synthetic TransactionStore."
            )
        }
        let leases = try lifecycle.beginOperation()
        let admissionResult: AdmissionResult
        do {
            admissionResult = try didAdmit()
        } catch {
            leases.work.end()
            leases.observer.end()
            throw error
        }
        _ = try await runtime.currentEntitlements(leases: leases)
        return admissionResult
    }

    /// Reconciles unfinished transactions and publishes current entitlements.
    ///
    /// Raw and typed entitlement values are validated and committed atomically.
    @discardableResult
    public func refreshEntitlements() async throws -> StoreEntitlements {
        let admission = try admit(operation: .refreshEntitlements)
        return try await admission.runtime.currentEntitlements(
            leases: admission.leases
        )
    }

    /// Returns verified transaction history for one product.
    ///
    /// Results are all-or-nothing and ordered newest first. A verification
    /// failure throws without returning partial results.
    public func history(
        for productID: Product.ID
    ) async throws -> [StoreTransactionSnapshot] {
        let admission = try admit(operation: .history)
        return try await admission.runtime.history(
            for: productID,
            leases: admission.leases
        )
    }

    /// Synchronizes App Store purchases and refreshes entitlements.
    ///
    /// If synchronization succeeds but refresh fails, this method throws
    /// ``StoreTransactionError/entitlementRefreshFailed(after:underlyingError:)``
    /// with ``StoreTransactionError/CompletedOperation/synchronizedPurchases``.
    @discardableResult
    public func restorePurchases() async throws -> StoreEntitlements {
        let admission = try admit(operation: .restorePurchases)
        return try await admission.runtime.restorePurchases(
            leases: admission.leases
        )
    }

    /// Stops producers and drains every operation accepted before closing.
    ///
    /// The first call seals admission and starts one shared terminal shutdown.
    /// Concurrent calls join it, and later calls return successfully. Caller
    /// cancellation does not abandon shutdown. Calling this method from a
    /// callback owned by this store throws
    /// ``StoreTransactionError/reentrantOperation(operation:)``.
    public func close() async throws {
        try rejectReentrancy(operation: .close)
        switch backend {
        case .liveRuntime(let runtime, let lifecycle),
            .syntheticRuntime(let runtime, let lifecycle, _):
            await lifecycle.close {
                await runtime.shutdown()
            }
        case .override:
            return
        }
    }

    package func waitForInitialReadiness() async throws {
        switch backend {
        case .liveRuntime(let runtime, _),
            .syntheticRuntime(let runtime, _, _):
            try await runtime.waitForInitialReadiness()
        case .override:
            return
        }
    }

    package func waitUntilClosing() async {
        switch backend {
        case .liveRuntime(_, let lifecycle),
            .syntheticRuntime(_, let lifecycle, _):
            await lifecycle.waitUntilSealed()
        case .override:
            return
        }
    }

    fileprivate func apply(
        _ outcome: EntitlementRefreshOutcome<Entitlement>
    ) {
        switch outcome {
        case .success(let publication):
            availability = .ready(
                entitlements: publication.entitlements,
                activeEntitlements: publication.activeEntitlements
            )
        case .transientFailure(let error):
            guard case .ready = availability else {
                availability = .failed(error)
                return
            }
        case .catalogFailure(let error):
            availability = .failed(error)
        }
    }

    private func admit(
        operation: StoreTransactionOperation
    ) throws -> RuntimeAdmission {
        try rejectReentrancy(operation: operation)
        switch backend {
        case .liveRuntime(let runtime, let lifecycle):
            return RuntimeAdmission(
                runtime: runtime,
                leases: try lifecycle.beginOperation()
            )
        case .syntheticRuntime(
            let runtime,
            let lifecycle,
            let unavailableOperationError
        ):
            let leases = try lifecycle.beginOperation()
            guard operation == .refreshEntitlements else {
                leases.work.end()
                leases.observer.end()
                throw unavailableOperationError(operation)
            }
            return RuntimeAdmission(runtime: runtime, leases: leases)
        case .override:
            throw StoreTransactionError.operationUnavailableInOverride(
                operation: operation
            )
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
        switch backend {
        case .liveRuntime(let runtime, let lifecycle),
            .syntheticRuntime(let runtime, let lifecycle, _):
            lifecycle.sealSynchronously()
            runtime.cancelSynchronously()
        case .override:
            return
        }
    }
}

@MainActor
private final class TransactionStoreAvailabilityOwner<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    private weak var store: TransactionStore<Entitlement>?

    func attach(_ store: TransactionStore<Entitlement>) {
        precondition(self.store == nil)
        self.store = store
    }

    func apply(_ outcome: EntitlementRefreshOutcome<Entitlement>) {
        guard let store else { return }
        store.apply(outcome)
    }
}
