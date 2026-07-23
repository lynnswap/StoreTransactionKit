import Foundation

package struct EntitlementPublication<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    package let entitlements: StoreEntitlements
    package let activeEntitlements: Set<Entitlement>
}

package enum EntitlementRefreshOutcome<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    case success(EntitlementPublication<Entitlement>)
    case transientFailure(any Error)
    case catalogFailure(AutoRenewableSubscriptionCatalogError)
}

package struct EntitlementRefreshReservation<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case observer
    }

    package let receipt: ProcessingReceipt<EntitlementPublication<Entitlement>>
    package let role: Role
    package let reportingAuthority: DirectOperationReportingAuthority
    package let directBinding: DirectOperationObservation.Binding?
}

package actor EntitlementRefreshCoordinator<Entitlement>
where Entitlement: Hashable & Sendable {
    private struct PendingReservation: Sendable {
        let retryFailedTransactions: Bool
        let receipt: ProcessingReceipt<EntitlementPublication<Entitlement>>
        let reportingAuthority: DirectOperationReportingAuthority
    }

    private struct PendingFailureResolution: Sendable {
        let claim: TransactionCausalResolutionClaim<StoreTransactionSnapshot>
        let error: any Error
    }

    private enum PendingWork: Sendable {
        case refresh(PendingReservation)
        case failure(PendingFailureResolution)
    }

    private let query: @Sendable (Bool) async throws -> CurrentEntitlementReconciliation
    private let project:
        @Sendable (StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
            -> Set<Entitlement>
    private let didComplete: @Sendable (EntitlementRefreshOutcome<Entitlement>) async -> Void
    private let failures: FailureReporterDispatcher
    private let lifetime: TransactionStoreLifecycle?
    private let reservationDidEnqueue: (@Sendable () -> Void)?
    private var current: StoreEntitlements?
    private var pending: [PendingWork] = []
    private var worker: Task<Void, Never>?
    private var acceptsReservations = true
    private nonisolated let workerCancellation = TaskCancellationBag()

    package init(
        query:
            @escaping @Sendable (Bool) async throws
            -> CurrentEntitlementReconciliation,
        project:
            @escaping @Sendable (StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
            -> Set<Entitlement>,
        didComplete:
            @escaping @Sendable (EntitlementRefreshOutcome<Entitlement>) async
            -> Void,
        failures: FailureReporterDispatcher,
        lifetime: TransactionStoreLifecycle? = nil,
        reservationDidEnqueue: (@Sendable () -> Void)? = nil
    ) {
        self.query = query
        self.project = project
        self.didComplete = didComplete
        self.failures = failures
        self.lifetime = lifetime
        self.reservationDidEnqueue = reservationDidEnqueue
    }

    package func reserve(
        retryFailedTransactions: Bool = true,
        directObservation: DirectOperationObservation? = nil,
        reportingAuthority preferredReportingAuthority:
            DirectOperationReportingAuthority? = nil
    ) -> EntitlementRefreshReservation<Entitlement> {
        guard acceptsReservations else {
            return EntitlementRefreshReservation(
                receipt: .failed(
                    StoreTransactionInternalError.entitlementRefreshClosed
                ),
                role: .owner,
                reportingAuthority: DirectOperationReportingAuthority(),
                directBinding: nil
            )
        }

        let role: EntitlementRefreshReservation<Entitlement>.Role
        let reportingAuthority: DirectOperationReportingAuthority
        if case .refresh(let preceding)? = pending.last,
            preceding.retryFailedTransactions == retryFailedTransactions
        {
            role = .observer
            reportingAuthority = preceding.reportingAuthority
            preferredReportingAuthority?.merge(into: reportingAuthority)
        } else {
            role = .owner
            reportingAuthority =
                preferredReportingAuthority
                ?? DirectOperationReportingAuthority()
        }
        let receipt = ProcessingReceipt<EntitlementPublication<Entitlement>>()
        let directBinding = directObservation?.bind(to: reportingAuthority)
        pending.append(
            .refresh(
                PendingReservation(
                    retryFailedTransactions: retryFailedTransactions,
                    receipt: receipt,
                    reportingAuthority: reportingAuthority
                )
            )
        )
        reservationDidEnqueue?()
        startWorkerIfNeeded()
        return EntitlementRefreshReservation(
            receipt: receipt,
            role: role,
            reportingAuthority: reportingAuthority,
            directBinding: directBinding
        )
    }

    package func resolve(
        _ claim: TransactionCausalResolutionClaim<StoreTransactionSnapshot>,
        failure error: any Error
    ) {
        precondition(acceptsReservations)
        pending.append(
            .failure(
                PendingFailureResolution(
                    claim: claim,
                    error: error
                )
            )
        )
        startWorkerIfNeeded()
    }

    package func sealAndDrain() async {
        acceptsReservations = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(pending.isEmpty)
    }

    package nonisolated func cancelSynchronously() {
        workerCancellation.cancel()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runWork()
        }
        worker = task
        workerCancellation.insert(task)
    }

    private func runWork() async {
        while !pending.isEmpty {
            switch pending[0] {
            case .failure(let resolution):
                pending.removeFirst()
                await commitFailure(
                    resolution.error,
                    causalFailures: [
                        CurrentEntitlementCausalFailure(
                            claim: resolution.claim,
                            error: resolution.error
                        )
                    ],
                    reservationReceipts: []
                )

            case .refresh(let first):
                let end =
                    pending.firstIndex { work in
                        guard case .refresh(let reservation) = work else {
                            return true
                        }
                        return reservation.retryFailedTransactions
                            != first.retryFailedTransactions
                    } ?? pending.endIndex
                let work = Array(pending[..<end])
                pending.removeFirst(end)
                let reservations = work.map { work in
                    guard case .refresh(let reservation) = work else {
                        preconditionFailure()
                    }
                    return reservation
                }
                await runQuery(
                    retryFailedTransactions: first.retryFailedTransactions,
                    reservations: reservations
                )
            }
        }
        worker = nil
        workerCancellation.removeAll()
    }

    private func runQuery(
        retryFailedTransactions: Bool,
        reservations: [PendingReservation]
    ) async {
        let reconciliation: CurrentEntitlementReconciliation
        do {
            reconciliation = try await query(retryFailedTransactions)
        } catch let failure as CurrentEntitlementReconciliationFailure {
            merge(
                failure.rootReportingAuthorities,
                into: reservations[0].reportingAuthority
            )
            await commitFailure(
                failure.underlyingError,
                causalFailures: failure.causalFailures,
                reservationReceipts: reservations.map(\.receipt),
                reservationHasReportingOwner:
                    !failure.exactFailures.isEmpty,
                exactFailures: failure.exactFailures
            )
            await report(failure.exactFailures)
            await report(failure.diagnostics)
            return
        } catch {
            await commitFailure(
                error,
                causalFailures: [],
                reservationReceipts: reservations.map(\.receipt)
            )
            return
        }

        let queried = reconciliation.snapshots.sorted(
            by: Self.entitlementOrder
        )
        let entitlements: StoreEntitlements
        if let current, current.transactions == queried {
            entitlements = current
        } else {
            entitlements = StoreEntitlements(transactions: queried)
        }

        do {
            merge(
                reconciliation.causalClaims.map(\.reportingAuthority),
                into: reservations[0].reportingAuthority
            )
            let publication = EntitlementPublication(
                entitlements: entitlements,
                activeEntitlements: try project(entitlements)
            )
            current = entitlements
            await didComplete(.success(publication))
            for claim in reconciliation.causalClaims {
                await claim.succeed()
            }
            for reservation in reservations {
                reservation.receipt.succeed(publication)
            }
        } catch let error {
            await didComplete(.catalogFailure(error))
            for claim in reconciliation.causalClaims {
                await claim.fail(error)
            }
            for reservation in reservations {
                reservation.receipt.fail(error)
            }
        }
        await report(reconciliation.diagnostics)
    }

    private func commitFailure(
        _ error: any Error,
        causalFailures: [CurrentEntitlementCausalFailure],
        reservationReceipts:
            [ProcessingReceipt<EntitlementPublication<Entitlement>>],
        reservationHasReportingOwner: Bool = false,
        exactFailures: [CurrentEntitlementExactFailure] = []
    ) async {
        let exposed: any Error
        if let catalogFailure = error as? StoreTransactionCatalogFailure {
            exposed = catalogFailure.error
            await didComplete(.catalogFailure(catalogFailure.error))
        } else {
            exposed = error
            await didComplete(.transientFailure(error))
        }
        for failure in exactFailures where failure.isCausalOwner {
            failure.reportingAuthority.record(
                report: exactFailureReport(failure)
            )
        }
        for failure in causalFailures {
            await failure.claim.fail(exposedError(failure.error))
        }
        let reservationError: any Error =
            if reservationHasReportingOwner {
                StoreTransactionFailureWithReportingOwner(
                    underlyingError: exposed
                )
            } else {
                exposed
            }
        for receipt in reservationReceipts {
            receipt.fail(reservationError)
        }
    }

    private func report(
        _ exactFailures: [CurrentEntitlementExactFailure]
    ) async {
        for failure in exactFailures where failure.isCausalOwner {
            let report = exactFailureReport(failure)
            if let claimed = failure.reportingAuthority
                .failWithoutParticipant(report: report)
            {
                await failures.enqueue(claimed)
            }
        }
    }

    private func exactFailureReport(
        _ failure: CurrentEntitlementExactFailure
    ) -> StoreTransactionBackgroundFailure {
        StoreTransactionBackgroundFailure(
            source: .unfinished,
            transactionID: failure.snapshot.id,
            productID: failure.snapshot.productID,
            underlyingError: exposedError(failure.underlyingError)
        )
    }

    private func report(_ diagnostics: [StoreTransactionBackgroundFailure]) async {
        for diagnostic in diagnostics {
            await failures.enqueue(diagnostic)
        }
    }

    private func merge(
        _ authorities: [DirectOperationReportingAuthority],
        into reportingAuthority: DirectOperationReportingAuthority
    ) {
        for authority in authorities {
            authority.merge(into: reportingAuthority)
        }
    }

    private func exposedError(_ error: any Error) -> any Error {
        if let catalogFailure = error as? StoreTransactionCatalogFailure {
            return catalogFailure.error
        }
        return error
    }

    package nonisolated static func entitlementOrder(
        _ lhs: StoreTransactionSnapshot,
        _ rhs: StoreTransactionSnapshot
    ) -> Bool {
        if lhs.productID != rhs.productID {
            return Data(lhs.productID.utf8)
                .lexicographicallyPrecedes(Data(rhs.productID.utf8))
        }
        if lhs.purchaseDate != rhs.purchaseDate {
            return lhs.purchaseDate < rhs.purchaseDate
        }
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return Data(lhs.jwsRepresentation.utf8)
            .lexicographicallyPrecedes(Data(rhs.jwsRepresentation.utf8))
    }

    isolated deinit {
        worker?.cancel()
    }
}
