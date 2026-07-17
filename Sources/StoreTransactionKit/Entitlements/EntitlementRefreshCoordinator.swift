import Foundation

package struct EntitlementRefreshReservation: Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case observer
    }

    package let receipt: ProcessingReceipt<StoreEntitlements>
    package let role: Role
    package let token: UInt64
    package let reportingAuthority: DirectOperationReportingAuthority
}

package struct EntitlementRefreshSuccess: Sendable {
    package let token: UInt64
    package let entitlements: StoreEntitlements
}

package actor EntitlementRefreshCoordinator {
    private struct PendingReservation: Sendable {
        let token: UInt64
        let retryFailedTransactions: Bool
        let receipt: ProcessingReceipt<StoreEntitlements>
        let reportingAuthority: DirectOperationReportingAuthority
    }

    private let sessionID: UUID
    private let query: @Sendable (Bool) async throws -> [StoreTransactionSnapshot]
    private let didChange: @Sendable (StoreEntitlements) async -> Void
    private let didSucceed: @Sendable (EntitlementRefreshSuccess) async -> Void
    private var nextToken: UInt64 = 0
    private var current: StoreEntitlements?
    private var pending: [PendingReservation] = []
    private var worker: Task<Void, Never>?
    private var acceptsReservations = true

    package init(
        sessionID: UUID = UUID(),
        query:
            @escaping @Sendable (Bool) async throws
            -> [StoreTransactionSnapshot],
        didChange: @escaping @Sendable (StoreEntitlements) async -> Void,
        didSucceed:
            @escaping @Sendable (EntitlementRefreshSuccess) async -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.query = query
        self.didChange = didChange
        self.didSucceed = didSucceed
    }

    package func reserve(
        retryFailedTransactions: Bool = true
    ) -> EntitlementRefreshReservation {
        guard acceptsReservations else {
            return EntitlementRefreshReservation(
                receipt: .failed(
                    StoreTransactionInternalError.entitlementRefreshClosed
                ),
                role: .owner,
                token: 0,
                reportingAuthority: DirectOperationReportingAuthority()
            )
        }
        precondition(nextToken < .max)
        nextToken += 1
        let role: EntitlementRefreshReservation.Role
        let reportingAuthority: DirectOperationReportingAuthority
        if let preceding = pending.last,
            preceding.retryFailedTransactions == retryFailedTransactions
        {
            role = .observer
            reportingAuthority = preceding.reportingAuthority
        } else {
            role = .owner
            reportingAuthority = DirectOperationReportingAuthority()
        }
        let receipt = ProcessingReceipt<StoreEntitlements>()
        pending.append(
            PendingReservation(
                token: nextToken,
                retryFailedTransactions: retryFailedTransactions,
                receipt: receipt,
                reportingAuthority: reportingAuthority
            )
        )
        startWorkerIfNeeded()
        return EntitlementRefreshReservation(
            receipt: receipt,
            role: role,
            token: nextToken,
            reportingAuthority: reportingAuthority
        )
    }

    package func sealAndDrain() async {
        acceptsReservations = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(pending.isEmpty)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task.detached { [weak self] in
            guard let self else { return }
            await self.runQueries()
        }
    }

    private func runQueries() async {
        while !pending.isEmpty {
            let retryFailedTransactions =
                pending[0].retryFailedTransactions
            let end =
                pending.firstIndex {
                    $0.retryFailedTransactions != retryFailedTransactions
                } ?? pending.endIndex
            let reservations = Array(pending[..<end])
            pending.removeFirst(end)
            do {
                let queried = try await query(retryFailedTransactions)
                    .sorted(by: Self.entitlementOrder)
                let published: StoreEntitlements
                if let current, current.transactions == queried {
                    published = current
                } else {
                    published = StoreEntitlements(transactions: queried)
                    current = published
                    await StoreTransactionCallbackContext.$current.withValue(
                        StoreTransactionCallbackInvocation(
                            sessionID: sessionID,
                            callback: .entitlementObserver
                        )
                    ) {
                        await didChange(published)
                    }
                }
                await didSucceed(
                    EntitlementRefreshSuccess(
                        token: reservations.last!.token,
                        entitlements: published
                    ))
                for reservation in reservations {
                    reservation.receipt.succeed(published)
                }
            } catch {
                for reservation in reservations {
                    reservation.receipt.fail(error)
                }
            }
        }
        worker = nil
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
