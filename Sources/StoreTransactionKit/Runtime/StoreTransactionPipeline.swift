package final class StoreTransactionPipeline<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    private let core: TransactionProcessingCore<StoreTransactionSnapshot>
    private let entitlements: EntitlementRefreshCoordinator<Entitlement>
    private let failures: FailureReporterDispatcher

    package init(
        core: TransactionProcessingCore<StoreTransactionSnapshot>,
        entitlements: EntitlementRefreshCoordinator<Entitlement>,
        failures: FailureReporterDispatcher
    ) {
        self.core = core
        self.entitlements = entitlements
        self.failures = failures
    }

    package func accept(
        _ delivery: StoreTransactionDelivery,
        directObservation: DirectOperationObservation? = nil
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
                await core.accept(
                    envelope,
                    directObservation: directObservation
                ),
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
        let accepted:
            (
                snapshot: StoreTransactionSnapshot,
                acceptance: ProcessingAcceptance<StoreTransactionSnapshot>,
                retryFailedTransactions: Bool
            )
        do {
            accepted = try await accept(delivery)
        } catch {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: source,
                    transactionID: nil,
                    productID: nil,
                    underlyingError: exposedError(error)
                )
            )
            return
        }

        let claim = await accepted.acceptance.claimCausalResolutionIfOwner()
        do {
            _ = try await accepted.acceptance.receipt.terminalValue()
        } catch {
            if let claim {
                await entitlements.resolve(claim, failure: error)
            }
            _ = try? await accepted.acceptance.causalReceipt.terminalValue()
            await reportIfBackgroundOwned(
                authority: accepted.acceptance.reportingAuthority,
                source: source,
                snapshot: accepted.snapshot,
                error: error
            )
            return
        }

        if let claim {
            let refresh = await entitlements.reserve(
                retryFailedTransactions: accepted.retryFailedTransactions,
                reportingAuthority:
                    accepted.acceptance.reportingAuthority
            )
            do {
                _ = try await refresh.receipt.terminalValue()
                await claim.succeed()
            } catch {
                await claim.fail(error)
            }
        }

        do {
            _ = try await accepted.acceptance.causalReceipt.terminalValue()
        } catch {
            await reportIfBackgroundOwned(
                authority: accepted.acceptance.reportingAuthority,
                source: .entitlementRefresh,
                snapshot: accepted.snapshot,
                error: error
            )
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
            let report = StoreTransactionBackgroundFailure(
                source: .entitlementRefresh,
                transactionID: nil,
                productID: nil,
                underlyingError: exposedError(propagation.underlyingError)
            )
            if let claimed = refresh.reportingAuthority.failWithoutParticipant(
                report: report
            ) {
                await failures.enqueue(claimed)
            }
        }
    }

    private func reportIfBackgroundOwned(
        authority: DirectOperationReportingAuthority,
        source: StoreTransactionBackgroundFailure.Source,
        snapshot: StoreTransactionSnapshot,
        error: any Error
    ) async {
        let report = StoreTransactionBackgroundFailure(
            source: source,
            transactionID: snapshot.id,
            productID: snapshot.productID,
            underlyingError: exposedError(error)
        )
        if let claimed = authority.failWithoutParticipant(report: report) {
            await failures.enqueue(claimed)
        }
    }

    private func exposedError(_ error: any Error) -> any Error {
        let propagation = StoreTransactionFailurePropagation(error)
        if let catalogFailure =
            propagation.underlyingError as? StoreTransactionCatalogFailure
        {
            return catalogFailure.error
        }
        return propagation.underlyingError
    }
}
