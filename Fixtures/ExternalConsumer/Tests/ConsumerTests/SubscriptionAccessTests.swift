import Consumer
import StoreTransactionKit
import StoreTransactionKitTesting
import StoreKit
import Testing

@Test
func catalogExposesStoreKitProductLookupInputs() {
    #expect(subscriptionCatalog.subscriptionGroupID == Plans.id)
    #expect(
        subscriptionProductIDs
            == [
                Plans.ProductID.tier1_Monthly.rawValue,
                Plans.ProductID.tier1_Yearly.rawValue,
                Plans.ProductID.tier2_Monthly.rawValue,
                Plans.ProductID.tier2_Yearly.rawValue,
            ]
    )
    #expect(
        entitlement(for: Plans.ProductID.tier1_Yearly.rawValue)
            == .tier1
    )
    #expect(entitlement(for: "external-consumer.unknown") == nil)
}

@Test
@MainActor
func tier1PurchaseAndExpirationUpdateViewModel() async throws {
    try await withTransactionStoreTestHarness(
        subscriptionCatalog: subscriptionCatalog
    ) { harness in
        let viewModel = NotesViewModel(store: harness.store)

        #expect(!viewModel.hasPremiumAccess)
        #expect(!viewModel.canExportPDF)

        let transaction = try await harness.purchase(
            .tier1_Monthly,
            in: Plans.self
        )

        #expect(transaction.productID == Plans.ProductID.tier1_Monthly.rawValue)
        #expect(viewModel.hasPremiumAccess)
        #expect(viewModel.canExportPDF)

        #expect(
            try await harness.expireActiveSubscription()
                == transaction
        )
        #expect(!viewModel.hasPremiumAccess)
        #expect(!viewModel.canExportPDF)
    }
}

@Test
@MainActor
func tier2GrantsCommonPremiumWithoutTier1Export() async throws {
    try await withTransactionStoreTestHarness(
        subscriptionCatalog: subscriptionCatalog
    ) { harness in
        let viewModel = NotesViewModel(store: harness.store)

        _ = try await harness.purchase(
            .tier2_Monthly,
            in: Plans.self
        )

        #expect(viewModel.hasPremiumAccess)
        #expect(!viewModel.canExportPDF)
    }
}

@Test
@MainActor
func unrecognizedSubscriptionUpdatesViewModel() async throws {
    let delegate = AppUnrecognizedSubscriptionDelegate()

    try await withTransactionStoreTestHarness(
        subscriptionCatalog: subscriptionCatalog,
        unrecognizedSubscriptionDelegate: delegate
    ) { harness in
        let viewModel = NotesViewModel(store: harness.store)
        let transaction = try harness.makeUnrecognizedSubscription(
            productID: legacySubscriptionProductID,
            in: Plans.self
        )

        #expect(!viewModel.canExportPDF)
        #expect(
            try await harness.deliver(transaction)
                == .completed(transaction)
        )
        #expect(harness.store.entitlements?.transactions == [transaction])
        #expect(viewModel.canExportPDF)
    }
}

@Test
@MainActor
func unmanagedTransactionUsesProductionDelegateRoute() async throws {
    let delegate = ExternalUnmanagedTransactionDelegate()

    try await withTransactionStoreTestHarness(
        subscriptionCatalog: subscriptionCatalog,
        delegate: delegate
    ) { harness in
        let transaction = harness.makeTransaction(
            productID: "external-consumer.tokens",
            productType: .consumable
        )
        let outcome = try await harness.deliver(transaction)

        #expect(outcome == .completed(transaction))
        #expect(await delegate.transactions == [transaction])
        #expect(harness.store.entitlements?.transactions == [])
        #expect(harness.store.activeEntitlements == [])
    }
}

private actor ExternalUnmanagedTransactionDelegate:
    TransactionStoreDelegate
{
    private(set) var transactions: [StoreTransactionSnapshot] = []

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        transactions.append(transaction)
        return .finish
    }
}
