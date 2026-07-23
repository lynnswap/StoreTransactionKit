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
