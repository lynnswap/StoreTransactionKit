import Consumer
import StoreTransactionKit
import StoreTransactionKitTesting
import Testing

@Test
@MainActor
func subscriptionUpdatesViewModel() async throws {
    try await withTransactionStoreTestHarness(
        subscriptionCatalog: subscriptionCatalog
    ) { harness in
        let viewModel = NotesViewModel(store: harness.store)

        #expect(!viewModel.canExportPDF)

        let transaction = try await harness.purchase(
            .tier1_Monthly,
            in: Plans.self
        )

        #expect(transaction.productID == Plans.ProductID.tier1_Monthly.rawValue)
        #expect(viewModel.canExportPDF)
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
