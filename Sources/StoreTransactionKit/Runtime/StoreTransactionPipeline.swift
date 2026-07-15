package final class StoreTransactionPipeline: Sendable {
    private let core: TransactionProcessingCore<StoreTransactionSnapshot>
    private let entitlements: EntitlementRefreshCoordinator
    private let failures: FailureReporterDispatcher

    package init(
        core: TransactionProcessingCore<StoreTransactionSnapshot>,
        entitlements: EntitlementRefreshCoordinator,
        failures: FailureReporterDispatcher
    ) {
        self.core = core
        self.entitlements = entitlements
        self.failures = failures
    }

    package func accept(
        _ delivery: StoreTransactionDelivery
    ) async throws -> (
        snapshot: StoreTransactionSnapshot,
        receipt: ProcessingReceipt<StoreTransactionSnapshot>
    ) {
        switch delivery {
        case .verified(let envelope):
            return (envelope.value, await core.accept(envelope))
        case .unverified(let error):
            throw error
        }
    }

    package func processBackground(
        _ delivery: StoreTransactionDelivery,
        source: StoreTransactionBackgroundFailure.Source
    ) async {
        let snapshot: StoreTransactionSnapshot?
        let receipt: ProcessingReceipt<StoreTransactionSnapshot>
        do {
            let accepted = try await accept(delivery)
            snapshot = accepted.snapshot
            receipt = accepted.receipt
        } catch {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: source,
                    transactionID: nil,
                    productID: nil,
                    underlyingError: error
                ))
            return
        }

        do {
            _ = try await receipt.terminalValue()
        } catch {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: source,
                    transactionID: snapshot?.id,
                    productID: snapshot?.productID,
                    underlyingError: error
                ))
            return
        }

        do {
            let refresh = await entitlements.reserve()
            _ = try await refresh.terminalValue()
        } catch {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: .entitlementRefresh,
                    transactionID: snapshot?.id,
                    productID: snapshot?.productID,
                    underlyingError: error
                ))
        }
    }

    package func reportAbandoned(
        operation: StoreTransactionOperation,
        snapshot: StoreTransactionSnapshot?,
        receipt: ProcessingReceipt<StoreTransactionSnapshot>
    ) async {
        do {
            _ = try await receipt.terminalValue()
            let refresh = await entitlements.reserve()
            _ = try await refresh.terminalValue()
        } catch {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: .abandonedDirectOperation(operation),
                    transactionID: snapshot?.id,
                    productID: snapshot?.productID,
                    underlyingError: error
                ))
        }
    }
}
