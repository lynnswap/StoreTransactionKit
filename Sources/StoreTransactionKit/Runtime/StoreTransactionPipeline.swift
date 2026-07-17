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
        acceptance: ProcessingAcceptance<StoreTransactionSnapshot>,
        retryFailedTransactions: Bool
    ) {
        switch delivery {
        case .verified(let envelope):
            let retryFailedTransactions = await core.beginTransactionAttempt()
            return (
                envelope.value,
                await core.accept(envelope),
                retryFailedTransactions
            )
        case .unverified(_, let error):
            throw error
        }
    }

    package func processBackground(
        _ delivery: StoreTransactionDelivery,
        source: StoreTransactionBackgroundFailure.Source
    ) async {
        let snapshot: StoreTransactionSnapshot?
        let acceptance: ProcessingAcceptance<StoreTransactionSnapshot>
        let retryFailedTransactions: Bool
        do {
            let accepted = try await accept(delivery)
            snapshot = accepted.snapshot
            acceptance = accepted.acceptance
            retryFailedTransactions = accepted.retryFailedTransactions
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

        await processAcceptedBackground(
            snapshot: snapshot,
            acceptance: acceptance,
            retryFailedTransactions: retryFailedTransactions,
            source: source
        )
    }

    package func processAcceptedBackground(
        snapshot: StoreTransactionSnapshot?,
        acceptance: ProcessingAcceptance<StoreTransactionSnapshot>,
        retryFailedTransactions: Bool = true,
        source: StoreTransactionBackgroundFailure.Source
    ) async {
        do {
            _ = try await acceptance.receipt.terminalValue()
        } catch {
            guard case .owner = acceptance.role else { return }
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: source,
                    transactionID: snapshot?.id,
                    productID: snapshot?.productID,
                    underlyingError: error
                ))
            return
        }

        if case .inFlightObserver = acceptance.role {
            return
        }
        let refresh = await entitlements.reserve(
            retryFailedTransactions: retryFailedTransactions
        )
        do {
            _ = try await refresh.receipt.terminalValue()
        } catch {
            let propagation = StoreTransactionFailurePropagation(error)
            guard !propagation.hasReportingOwner else { return }
            guard refresh.role == .owner else { return }
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: .entitlementRefresh,
                    transactionID: snapshot?.id,
                    productID: snapshot?.productID,
                    underlyingError: propagation.underlyingError
                ))
        }
    }

    package func refreshEntitlements() async {
        let retryFailedTransactions =
            await core.retryFailedTransactionsInNewAttempt()
        let refresh = await entitlements.reserve(
            retryFailedTransactions: retryFailedTransactions
        )
        do {
            _ = try await refresh.receipt.terminalValue()
        } catch {
            let propagation = StoreTransactionFailurePropagation(error)
            guard !propagation.hasReportingOwner else { return }
            guard refresh.role == .owner else { return }
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: .entitlementRefresh,
                    transactionID: nil,
                    productID: nil,
                    underlyingError: propagation.underlyingError
                ))
        }
    }
}
