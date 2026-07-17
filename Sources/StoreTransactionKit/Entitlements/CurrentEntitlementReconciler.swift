import Foundation
import StoreKit

package final class CurrentEntitlementReconciler: Sendable {
    struct AcceptedTransaction: Sendable {
        let snapshot: StoreTransactionSnapshot
        let acceptance: ProcessingAcceptance<StoreTransactionSnapshot>

        init(
            snapshot: StoreTransactionSnapshot,
            acceptance: ProcessingAcceptance<StoreTransactionSnapshot>
        ) {
            self.snapshot = snapshot
            self.acceptance = acceptance
        }
    }

    private struct UnfinishedBatch: Sendable {
        let revisions: Set<Data>
        let acceptedTransactions: [AcceptedTransaction]
        let verificationFailures: [UnfinishedVerificationFailure]
    }

    private struct UnfinishedVerificationFailure: Sendable {
        let revision: Data
        let error: any Error
    }

    private let currentEntitlements: @Sendable () async throws -> CurrentEntitlementQueryResult
    private let queryUnfinished: @Sendable () async -> [StoreTransactionDelivery]
    private let core: TransactionProcessingCore<StoreTransactionSnapshot>
    private let failures: FailureReporterDispatcher

    package init(
        query:
            @escaping @Sendable () async throws
            -> CurrentEntitlementQueryResult,
        queryUnfinished:
            @escaping @Sendable () async -> [StoreTransactionDelivery],
        core: TransactionProcessingCore<StoreTransactionSnapshot>,
        failures: FailureReporterDispatcher
    ) {
        self.currentEntitlements = query
        self.queryUnfinished = queryUnfinished
        self.core = core
        self.failures = failures
    }

    package func query(
        retryFailedTransactions: Bool
    ) async throws -> [StoreTransactionSnapshot] {
        if retryFailedTransactions {
            await core.beginRetryAttempt()
        }
        var reconciledRevisions: Set<Data> = []
        var batch = await unfinishedBatch(
            excluding: reconciledRevisions
        )
        var observedUnfinishedVerificationRevisions: Set<Data> = []
        var observedUnfinishedVerificationFailures: [any Error] = []
        collectUnfinishedVerificationFailures(
            batch.verificationFailures,
            observedRevisions: &observedUnfinishedVerificationRevisions,
            observedFailures: &observedUnfinishedVerificationFailures
        )
        var precedingCurrentVerificationFailures: [StoreTransactionVerificationError] = []

        while true {
            while !batch.acceptedTransactions.isEmpty {
                do {
                    try await drain(batch.acceptedTransactions)
                } catch {
                    await reportVerificationFailures(
                        unfinished: observedUnfinishedVerificationFailures,
                        currentEntitlements:
                            precedingCurrentVerificationFailures
                    )
                    throw error
                }
                reconciledRevisions.formUnion(batch.revisions)
                batch = await unfinishedBatch(
                    excluding: reconciledRevisions
                )
                collectUnfinishedVerificationFailures(
                    batch.verificationFailures,
                    observedRevisions:
                        &observedUnfinishedVerificationRevisions,
                    observedFailures:
                        &observedUnfinishedVerificationFailures
                )
            }

            let result: CurrentEntitlementQueryResult
            do {
                result = try await currentEntitlements()
            } catch {
                await reportUnfinishedVerificationFailures(
                    observedUnfinishedVerificationFailures
                )
                throw error
            }

            let postQueryBatch = await unfinishedBatch(
                excluding: reconciledRevisions
            )
            collectUnfinishedVerificationFailures(
                postQueryBatch.verificationFailures,
                observedRevisions:
                    &observedUnfinishedVerificationRevisions,
                observedFailures:
                    &observedUnfinishedVerificationFailures
            )
            guard !postQueryBatch.acceptedTransactions.isEmpty else {
                await reportVerificationFailures(
                    unfinished: observedUnfinishedVerificationFailures,
                    currentEntitlements: result.verificationFailures
                )
                return result.snapshots
            }
            batch = postQueryBatch
            precedingCurrentVerificationFailures =
                result.verificationFailures
        }
    }

    private func unfinishedBatch(
        excluding reconciledRevisions: Set<Data>
    ) async -> UnfinishedBatch {
        var revisions: Set<Data> = []
        var acceptedTransactions: [AcceptedTransaction] = []
        var verificationFailures: [UnfinishedVerificationFailure] = []

        for delivery in await queryUnfinished() {
            switch delivery {
            case .verified(let envelope):
                guard
                    !reconciledRevisions.contains(envelope.revision),
                    revisions.insert(envelope.revision).inserted
                else {
                    continue
                }
                acceptedTransactions.append(
                    AcceptedTransaction(
                        snapshot: envelope.value,
                        acceptance: await core.accept(envelope)
                    ))
            case .unverified(let revision, let error):
                verificationFailures.append(
                    UnfinishedVerificationFailure(
                        revision: revision,
                        error: error
                    ))
            }
        }

        return UnfinishedBatch(
            revisions: revisions,
            acceptedTransactions: acceptedTransactions,
            verificationFailures: verificationFailures
        )
    }

    private func collectUnfinishedVerificationFailures(
        _ verificationFailures: [UnfinishedVerificationFailure],
        observedRevisions: inout Set<Data>,
        observedFailures: inout [any Error]
    ) {
        for failure in verificationFailures
        where observedRevisions.insert(failure.revision).inserted {
            observedFailures.append(failure.error)
        }
    }

    private func reportVerificationFailures(
        unfinished: [any Error],
        currentEntitlements: [StoreTransactionVerificationError]
    ) async {
        await reportUnfinishedVerificationFailures(unfinished)
        await reportCurrentEntitlementVerificationFailures(
            currentEntitlements
        )
    }

    private func reportUnfinishedVerificationFailures(
        _ verificationFailures: [any Error]
    ) async {
        for failure in verificationFailures {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: .unfinished,
                    transactionID: nil,
                    productID: nil,
                    underlyingError: failure
                )
            )
        }
    }

    func drain(_ transactions: [AcceptedTransaction]) async throws {
        var firstError: (any Error)?
        for transaction in transactions {
            do {
                _ = try await transaction.acceptance.receipt.terminalValue()
            } catch {
                if transaction.acceptance.role == .owner {
                    let failure = StoreTransactionBackgroundFailure(
                        source: .unfinished,
                        transactionID: transaction.snapshot.id,
                        productID: transaction.snapshot.productID,
                        underlyingError: error
                    )
                    await failures.enqueue(failure)
                }
                if firstError == nil {
                    firstError = StoreTransactionFailureWithReportingOwner(
                        underlyingError: error
                    )
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func reportCurrentEntitlementVerificationFailures(
        _ verificationFailures: [StoreTransactionVerificationError]
    ) async {
        for failure in verificationFailures {
            await failures.enqueue(
                StoreTransactionBackgroundFailure(
                    source: .currentEntitlementVerification,
                    transactionID: nil,
                    productID: nil,
                    underlyingError: failure
                )
            )
        }
    }
}
