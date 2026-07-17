import Foundation

package struct EntitlementRefreshReservation: Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case observer
    }

    package let receipt: ProcessingReceipt<StoreEntitlements>
    package let role: Role
}

package actor EntitlementRefreshCoordinator {
    private struct PendingReservation: Sendable {
        let token: UInt64
        let retryFailedTransactions: Bool
        let receipt: ProcessingReceipt<StoreEntitlements>
    }

    private let sessionID: UUID
    private let query: @Sendable (Bool) async throws -> [StoreTransactionSnapshot]
    private let didChange: @Sendable (StoreEntitlements) async -> Void
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
        didChange: @escaping @Sendable (StoreEntitlements) async -> Void
    ) {
        self.sessionID = sessionID
        self.query = query
        self.didChange = didChange
    }

    package func reserve(
        retryFailedTransactions: Bool = true
    ) -> EntitlementRefreshReservation {
        guard acceptsReservations else {
            return EntitlementRefreshReservation(
                receipt: .failed(
                    StoreTransactionInternalError.entitlementRefreshClosed
                ),
                role: .owner
            )
        }
        precondition(nextToken < .max)
        nextToken += 1
        let role: EntitlementRefreshReservation.Role =
            pending.last?.retryFailedTransactions == retryFailedTransactions
            ? .observer : .owner
        let receipt = ProcessingReceipt<StoreEntitlements>()
        pending.append(
            PendingReservation(
                token: nextToken,
                retryFailedTransactions: retryFailedTransactions,
                receipt: receipt
            )
        )
        startWorkerIfNeeded()
        return EntitlementRefreshReservation(receipt: receipt, role: role)
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
