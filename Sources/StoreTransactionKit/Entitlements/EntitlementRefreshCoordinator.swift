import Foundation

package actor EntitlementRefreshCoordinator {
    private struct Reservation: Sendable {
        let token: UInt64
        let receipt: ProcessingReceipt<StoreEntitlements>
    }

    private let sessionID: UUID
    private let query: @Sendable () async throws -> [StoreTransactionSnapshot]
    private let didChange: @Sendable (StoreEntitlements) async -> Void
    private var nextToken: UInt64 = 0
    private var current: StoreEntitlements?
    private var pending: [Reservation] = []
    private var worker: Task<Void, Never>?
    private var acceptsReservations = true

    package init(
        sessionID: UUID = UUID(),
        query:
            @escaping @Sendable () async throws
            -> [StoreTransactionSnapshot],
        didChange: @escaping @Sendable (StoreEntitlements) async -> Void
    ) {
        self.sessionID = sessionID
        self.query = query
        self.didChange = didChange
    }

    package func reserve() -> ProcessingReceipt<StoreEntitlements> {
        guard acceptsReservations else {
            return .failed(StoreTransactionInternalError.entitlementRefreshClosed)
        }
        precondition(nextToken < .max)
        nextToken += 1
        let receipt = ProcessingReceipt<StoreEntitlements>()
        pending.append(Reservation(token: nextToken, receipt: receipt))
        startWorkerIfNeeded()
        return receipt
    }

    package func sealAndDrain() async {
        acceptsReservations = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(pending.isEmpty)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            await runQueries()
        }
    }

    private func runQueries() async {
        while !pending.isEmpty {
            let reservations = pending
            pending.removeAll(keepingCapacity: true)
            do {
                let queried = try await query().sorted(by: Self.entitlementOrder)
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
