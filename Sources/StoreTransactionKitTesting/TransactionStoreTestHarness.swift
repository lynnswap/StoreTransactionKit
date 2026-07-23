import StoreTransactionKit

/// A StoreKit-free driver for a production ``TransactionStore`` data flow.
@MainActor
public final class TransactionStoreTestHarness<Entitlement>
where Entitlement: Hashable & Sendable {
    /// The production transaction store supplied to the app component under test.
    public let store: TransactionStore<Entitlement>

    private let subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>
    private let currentEntitlements: SyntheticCurrentEntitlements

    private init(
        store: TransactionStore<Entitlement>,
        subscriptionCatalog:
            AutoRenewableSubscriptionCatalog<Entitlement>,
        currentEntitlements: SyntheticCurrentEntitlements
    ) {
        self.store = store
        self.subscriptionCatalog = subscriptionCatalog
        self.currentEntitlements = currentEntitlements
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

        let rawProductID = productID.rawValue
        guard subscriptionCatalog.contains(productID: rawProductID) else {
            throw TransactionStoreTestHarnessError.undeclaredProduct(
                productID: rawProductID,
                subscriptionGroupID: Group.id
            )
        }

        try Task.checkCancellation()
        let snapshot = currentEntitlements.makeSnapshot(
            productID: rawProductID,
            subscriptionGroupID: Group.id
        )
        return try await store.processSyntheticDelivery(
            .synthetic(snapshot: snapshot) { [currentEntitlements] in
                await currentEntitlements.replace(with: snapshot)
            }
        )
    }

    static func make(
        subscriptionCatalog:
            AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)?
    ) async throws -> TransactionStoreTestHarness<Entitlement> {
        let currentEntitlements = SyntheticCurrentEntitlements()
        let syntheticSource = SyntheticStoreTransactionSource {
            await currentEntitlements.snapshots()
        }
        let store = TransactionStore(
            subscriptionCatalog: subscriptionCatalog,
            syntheticSource: syntheticSource,
            delegate: delegate,
            unavailableOperationError: {
                TransactionStoreTestHarnessError.operationUnavailable(
                    operation: $0
                )
            }
        )
        let harness = TransactionStoreTestHarness(
            store: store,
            subscriptionCatalog: subscriptionCatalog,
            currentEntitlements: currentEntitlements
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
