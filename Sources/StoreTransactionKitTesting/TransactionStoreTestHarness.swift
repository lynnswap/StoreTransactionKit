import StoreTransactionKit

/// A StoreKit-free driver for a production ``TransactionStore`` data flow.
@MainActor
public final class TransactionStoreTestHarness<Entitlement>
where Entitlement: Hashable & Sendable {
    /// The production transaction store supplied to the app component under test.
    public let store: TransactionStore<Entitlement>

    private let subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>
    private let ledger: SyntheticTransactionLedger

    private init(
        store: TransactionStore<Entitlement>,
        subscriptionCatalog:
            AutoRenewableSubscriptionCatalog<Entitlement>,
        ledger: SyntheticTransactionLedger
    ) {
        self.store = store
        self.subscriptionCatalog = subscriptionCatalog
        self.ledger = ledger
    }

    /// Simulates an immediately active purchase of a declared subscription product.
    ///
    /// The command completes after transaction policy, acknowledgement,
    /// entitlement reconciliation, and observable-state publication complete.
    @discardableResult
    public func purchase<Group>(
        _ productID: Group.ProductID,
        in groupType: Group.Type
    ) async throws -> StoreTransactionSnapshot
    where Group: AutoRenewableSubscriptionGroup<Entitlement> {
        try validate(groupType)

        let rawProductID = productID.rawValue
        guard subscriptionCatalog.contains(productID: rawProductID) else {
            throw TransactionStoreTestHarnessError.undeclaredProduct(
                productID: rawProductID,
                subscriptionGroupID: Group.id
            )
        }

        try Task.checkCancellation()
        let snapshot = ledger.makeRegisteredSnapshot(
            productID: rawProductID,
            subscriptionGroupID: Group.id
        )
        let outcome = try await store.processSyntheticDelivery(
            .synthetic(snapshot: snapshot) { [ledger] in
                await ledger.activate(snapshot)
            }
        )
        guard case .completed(let completed) = outcome else {
            preconditionFailure(
                "A declared synthetic purchase must complete its transaction."
            )
        }
        return completed
    }

    /// Creates an unrecognized subscription revision without delivering it.
    ///
    /// The product identifier must be nonempty and absent from the supplied
    /// group's catalog. The returned snapshot is registered to this harness and
    /// can be passed to ``deliver(_:)`` repeatedly to exercise retry and replay
    /// behavior.
    public func makeUnrecognizedSubscription<Group>(
        productID: String,
        in groupType: Group.Type
    ) throws -> StoreTransactionSnapshot
    where Group: AutoRenewableSubscriptionGroup<Entitlement> {
        try validate(groupType)
        precondition(
            !productID.isEmpty,
            "A synthetic subscription product identifier must not be empty."
        )
        guard !subscriptionCatalog.contains(productID: productID) else {
            throw TransactionStoreTestHarnessError.declaredProduct(
                productID: productID,
                subscriptionGroupID: Group.id
            )
        }

        return ledger.makeRegisteredSnapshot(
            productID: productID,
            subscriptionGroupID: Group.id
        )
    }

    /// Delivers an exact synthetic snapshot value registered by this harness.
    ///
    /// After admission, delivery makes the revision current unless a later
    /// synthetic transaction is already current, then runs the production
    /// policy and publication path. Re-delivering the same revision exercises
    /// the store's session policy and acknowledgement idempotency without
    /// rolling back a later subscription. A value not exactly registered by
    /// this harness throws ``TransactionStoreTestHarnessError/unregisteredTransaction(transactionID:)``
    /// before changing the synthetic current-entitlement source.
    @discardableResult
    public func deliver(
        _ transaction: StoreTransactionSnapshot
    ) async throws -> StorePurchaseOutcome {
        guard ledger.contains(transaction) else {
            throw TransactionStoreTestHarnessError.unregisteredTransaction(
                transactionID: transaction.id
            )
        }

        try Task.checkCancellation()
        return try await store.processSyntheticDelivery(
            .synthetic(
                snapshot: transaction,
                acknowledge: {}
            ),
            didAdmit: { [ledger] in
                await ledger.activate(transaction)
            }
        )
    }

    private func validate<Group>(
        _ groupType: Group.Type
    ) throws where Group: AutoRenewableSubscriptionGroup<Entitlement> {
        guard subscriptionCatalog.subscriptionGroupID == Group.id else {
            throw TransactionStoreTestHarnessError.subscriptionGroupMismatch(
                expected: subscriptionCatalog.subscriptionGroupID,
                actual: Group.id
            )
        }
        guard subscriptionCatalog.isDeclared(by: groupType) else {
            throw TransactionStoreTestHarnessError.subscriptionGroupTypeMismatch(
                subscriptionGroupID: Group.id
            )
        }
    }

    static func make(
        subscriptionCatalog:
            AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)?,
        unrecognizedSubscriptionDelegate:
            (any UnrecognizedSubscriptionDelegate<Entitlement>)?
    ) async throws -> TransactionStoreTestHarness<Entitlement> {
        let ledger = SyntheticTransactionLedger()
        let syntheticSource = SyntheticStoreTransactionSource {
            await ledger.snapshots()
        }
        let store = TransactionStore(
            subscriptionCatalog: subscriptionCatalog,
            syntheticSource: syntheticSource,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate,
            unavailableOperationError: {
                TransactionStoreTestHarnessError.operationUnavailable(
                    operation: $0
                )
            }
        )
        let harness = TransactionStoreTestHarness(
            store: store,
            subscriptionCatalog: subscriptionCatalog,
            ledger: ledger
        )

        do {
            try await store.waitForInitialReadiness()
            return harness
        } catch {
            let initializationError = error
            try await store.close()
            throw initializationError
        }
    }
}
