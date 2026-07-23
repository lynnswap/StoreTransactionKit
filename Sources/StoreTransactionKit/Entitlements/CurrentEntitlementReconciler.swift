import Foundation
import StoreKit

package struct CurrentEntitlementReconciliation: Sendable {
    package let snapshots: [StoreTransactionSnapshot]
    package let causalClaims: [TransactionCausalResolutionClaim<StoreTransactionSnapshot>]
    package let diagnostics: [StoreTransactionBackgroundFailure]
}

package struct CurrentEntitlementReconciliationFailure: Error, Sendable {
    package let underlyingError: any Error
    package let causalFailures: [CurrentEntitlementCausalFailure]
    package let rootReportingAuthorities: [DirectOperationReportingAuthority]
    package let exactFailures: [CurrentEntitlementExactFailure]
    package let diagnostics: [StoreTransactionBackgroundFailure]
}

package struct CurrentEntitlementCausalFailure: Sendable {
    package let claim: TransactionCausalResolutionClaim<StoreTransactionSnapshot>
    package let error: any Error
}

package struct CurrentEntitlementExactFailure: Sendable {
    package let snapshot: StoreTransactionSnapshot
    package let reportingAuthority: DirectOperationReportingAuthority
    package let underlyingError: any Error
    package let isCausalOwner: Bool
}

package final class CurrentEntitlementReconciler: Sendable {
    private struct AcceptedTransaction: Sendable {
        let snapshot: StoreTransactionSnapshot
        let acceptance: ProcessingAcceptance<StoreTransactionSnapshot>
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

    package init(
        query:
            @escaping @Sendable () async throws
            -> CurrentEntitlementQueryResult,
        queryUnfinished:
            @escaping @Sendable () async -> [StoreTransactionDelivery],
        core: TransactionProcessingCore<StoreTransactionSnapshot>
    ) {
        currentEntitlements = query
        self.queryUnfinished = queryUnfinished
        self.core = core
    }

    package func query(
        retryFailedTransactions: Bool
    ) async throws -> CurrentEntitlementReconciliation {
        if retryFailedTransactions {
            await core.beginRetryAttempt()
        }
        var reconciledRevisions: Set<Data> = []
        var batch = await unfinishedBatch(excluding: reconciledRevisions)
        var observedVerificationRevisions: Set<Data> = []
        var diagnostics: [StoreTransactionBackgroundFailure] = []
        var causalClaims: [TransactionCausalResolutionClaim<StoreTransactionSnapshot>] = []
        collectUnfinishedVerificationFailures(
            batch.verificationFailures,
            observedRevisions: &observedVerificationRevisions,
            diagnostics: &diagnostics
        )
        var precedingCurrentVerificationFailures: [StoreTransactionVerificationError] = []

        while true {
            while !batch.acceptedTransactions.isEmpty {
                do {
                    causalClaims.append(
                        contentsOf: try await drain(
                            batch.acceptedTransactions
                        )
                    )
                } catch let failure as DrainFailure {
                    appendCurrentEntitlementVerificationFailures(
                        precedingCurrentVerificationFailures,
                        to: &diagnostics
                    )
                    let rootCausalFailures = causalClaims.map {
                        CurrentEntitlementCausalFailure(
                            claim: $0,
                            error: failure.underlyingError
                        )
                    }
                    throw CurrentEntitlementReconciliationFailure(
                        underlyingError: failure.underlyingError,
                        causalFailures:
                            rootCausalFailures + failure.causalFailures,
                        rootReportingAuthorities:
                            causalClaims.map(\.reportingAuthority)
                            + failure.rootReportingAuthorities,
                        exactFailures: failure.exactFailures,
                        diagnostics: diagnostics
                    )
                } catch {
                    preconditionFailure("Unclassified reconciliation failure: \(error)")
                }
                reconciledRevisions.formUnion(batch.revisions)
                batch = await unfinishedBatch(excluding: reconciledRevisions)
                collectUnfinishedVerificationFailures(
                    batch.verificationFailures,
                    observedRevisions: &observedVerificationRevisions,
                    diagnostics: &diagnostics
                )
            }

            let result: CurrentEntitlementQueryResult
            do {
                result = try await currentEntitlements()
            } catch {
                throw CurrentEntitlementReconciliationFailure(
                    underlyingError: error,
                    causalFailures: causalClaims.map {
                        CurrentEntitlementCausalFailure(
                            claim: $0,
                            error: error
                        )
                    },
                    rootReportingAuthorities:
                        causalClaims.map(\.reportingAuthority),
                    exactFailures: [],
                    diagnostics: diagnostics
                )
            }

            let postQueryBatch = await unfinishedBatch(
                excluding: reconciledRevisions
            )
            collectUnfinishedVerificationFailures(
                postQueryBatch.verificationFailures,
                observedRevisions: &observedVerificationRevisions,
                diagnostics: &diagnostics
            )
            guard !postQueryBatch.acceptedTransactions.isEmpty else {
                appendCurrentEntitlementVerificationFailures(
                    result.verificationFailures,
                    to: &diagnostics
                )
                return CurrentEntitlementReconciliation(
                    snapshots: result.snapshots,
                    causalClaims: causalClaims,
                    diagnostics: diagnostics
                )
            }
            batch = postQueryBatch
            precedingCurrentVerificationFailures = result.verificationFailures
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
                    )
                )
            case .unverified(let revision, let error):
                verificationFailures.append(
                    UnfinishedVerificationFailure(
                        revision: revision,
                        error: error
                    )
                )
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
        diagnostics: inout [StoreTransactionBackgroundFailure]
    ) {
        for failure in verificationFailures
        where observedRevisions.insert(failure.revision).inserted {
            diagnostics.append(
                StoreTransactionBackgroundFailure(
                    source: .unfinished,
                    transactionID: nil,
                    productID: nil,
                    underlyingError: failure.error
                )
            )
        }
    }

    private struct DrainFailure: Error, Sendable {
        let underlyingError: any Error
        let causalFailures: [CurrentEntitlementCausalFailure]
        let rootReportingAuthorities: [DirectOperationReportingAuthority]
        let exactFailures: [CurrentEntitlementExactFailure]
    }

    private func drain(
        _ transactions: [AcceptedTransaction]
    ) async throws -> [TransactionCausalResolutionClaim<StoreTransactionSnapshot>] {
        var claimedTransactions:
            [(
                transaction: AcceptedTransaction,
                claim: TransactionCausalResolutionClaim<StoreTransactionSnapshot>?
            )] = []
        for transaction in transactions {
            claimedTransactions.append(
                (
                    transaction,
                    await transaction.acceptance.claimCausalResolutionIfOwner()
                )
            )
        }

        var exactFailures: [CurrentEntitlementExactFailure] = []
        for entry in claimedTransactions {
            do {
                _ = try await entry.transaction.acceptance.receipt.terminalValue()
            } catch {
                exactFailures.append(
                    CurrentEntitlementExactFailure(
                        snapshot: entry.transaction.snapshot,
                        reportingAuthority:
                            entry.transaction.acceptance.reportingAuthority,
                        underlyingError: error,
                        isCausalOwner: entry.claim != nil
                    )
                )
            }
        }
        if let firstFailure = exactFailures.first {
            let additionalOwnedAuthorities = exactFailures.dropFirst()
                .filter(\.isCausalOwner)
                .map(\.reportingAuthority)
            let causalFailures: [CurrentEntitlementCausalFailure] =
                claimedTransactions.compactMap { entry in
                    guard let claim = entry.claim else { return nil }
                    let exactError = exactFailures.first { failure in
                        failure.reportingAuthority
                            === entry.transaction.acceptance.reportingAuthority
                    }?.underlyingError
                    return CurrentEntitlementCausalFailure(
                        claim: claim,
                        error: exactError ?? firstFailure.underlyingError
                    )
                }
            let rootReportingAuthorities =
                causalFailures
                .map { $0.claim.reportingAuthority }
                .filter { authority in
                    !additionalOwnedAuthorities.contains {
                        $0 === authority
                    }
                } + [firstFailure.reportingAuthority]
            throw DrainFailure(
                underlyingError: firstFailure.underlyingError,
                causalFailures: causalFailures,
                rootReportingAuthorities: rootReportingAuthorities,
                exactFailures: exactFailures
            )
        }
        return claimedTransactions.compactMap(\.claim)
    }

    private func appendCurrentEntitlementVerificationFailures(
        _ verificationFailures: [StoreTransactionVerificationError],
        to diagnostics: inout [StoreTransactionBackgroundFailure]
    ) {
        for failure in verificationFailures {
            diagnostics.append(
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
