import Foundation
import StoreKit

package final class CurrentEntitlementReconciler: Sendable {
    private struct AcceptedTransaction: Sendable {
        let snapshot: StoreTransactionSnapshot
        let acceptance: ProcessingAcceptance<StoreTransactionSnapshot>
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

    package func query() async throws -> [StoreTransactionSnapshot] {
        var reconciledRevisions: Set<Data> = []

        while true {
            let result = try await currentEntitlements()
            let currentRevisions = Set(
                result.snapshots.map { Data($0.jwsRepresentation.utf8) }
            )
            var iterationRevisions: Set<Data> = []
            var acceptedTransactions: [AcceptedTransaction] = []

            for delivery in await queryUnfinished() {
                switch delivery {
                case .verified(let envelope):
                    let canChangeEntitlements =
                        envelope.value.productType != .consumable
                    guard
                        currentRevisions.contains(envelope.revision)
                            || canChangeEntitlements,
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
                case .unverified:
                    continue
                }
            }

            guard !acceptedTransactions.isEmpty else {
                await reportVerificationFailures(result.verificationFailures)
                return result.snapshots
            }

            try await drain(acceptedTransactions)
            reconciledRevisions.formUnion(iterationRevisions)
        }
    }

    private func drain(_ transactions: [AcceptedTransaction]) async throws {
        var firstError: (any Error)?
        for transaction in transactions {
            do {
                _ = try await transaction.acceptance.receipt.terminalValue()
            } catch {
                if transaction.acceptance.role == .owner {
                    await failures.enqueue(
                        StoreTransactionBackgroundFailure(
                            source: .unfinished,
                            transactionID: transaction.snapshot.id,
                            productID: transaction.snapshot.productID,
                            underlyingError: error
                        ))
                }
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func reportVerificationFailures(
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
