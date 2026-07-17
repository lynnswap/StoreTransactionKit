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

        while true {
            let result = try await currentEntitlements()
            var iterationRevisions: Set<Data> = []
            var acceptedTransactions: [AcceptedTransaction] = []
            var unfinishedVerificationFailures: [any Error] = []

            for delivery in await queryUnfinished() {
                switch delivery {
                case .verified(let envelope):
                    guard
                        !reconciledRevisions.contains(envelope.revision),
                        iterationRevisions.insert(envelope.revision).inserted
                    else {
                        continue
                    }
                    acceptedTransactions.append(
                        AcceptedTransaction(
                            snapshot: envelope.value,
                            acceptance: await core.accept(envelope)
                        ))
                case .unverified(let error):
                    unfinishedVerificationFailures.append(error)
                }
            }

            guard !acceptedTransactions.isEmpty else {
                await reportVerificationFailures(
                    unfinished: unfinishedVerificationFailures,
                    currentEntitlements: result.verificationFailures
                )
                return result.snapshots
            }

            do {
                try await drain(acceptedTransactions)
            } catch {
                await reportVerificationFailures(
                    unfinished: unfinishedVerificationFailures,
                    currentEntitlements: result.verificationFailures
                )
                throw error
            }
            reconciledRevisions.formUnion(iterationRevisions)
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
