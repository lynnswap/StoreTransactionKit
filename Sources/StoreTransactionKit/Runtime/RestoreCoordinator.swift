package struct RestoreReservation: Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case observer
    }

    package let receipt: ProcessingReceipt<StoreEntitlements>
    package let role: Role
}

package struct RestoreCoordinatorFailure: Error {
    package let underlyingError: any Error
    package let reportsWhenAbandoned: Bool

    package init(
        propagating error: any Error,
        reportsWhenAbandoned: Bool
    ) {
        let propagation = StoreTransactionFailurePropagation(error)
        self.underlyingError = propagation.underlyingError
        self.reportsWhenAbandoned =
            reportsWhenAbandoned && !propagation.hasReportingOwner
    }
}

package actor RestoreCoordinator {
    private struct InFlight: Sendable {
        let id: UInt64
        let receipt: ProcessingReceipt<StoreEntitlements>
        let task: Task<Void, Never>
    }

    private let synchronize: @Sendable () async throws -> Void
    private let entitlements: EntitlementRefreshCoordinator
    private var nextID: UInt64 = 0
    private var inFlight: InFlight?

    package init(
        synchronize: @escaping @Sendable () async throws -> Void,
        entitlements: EntitlementRefreshCoordinator
    ) {
        self.synchronize = synchronize
        self.entitlements = entitlements
    }

    package func reserve() -> RestoreReservation {
        if let inFlight {
            return RestoreReservation(
                receipt: inFlight.receipt,
                role: .observer
            )
        }

        precondition(nextID < .max)
        nextID += 1
        let id = nextID
        let receipt = ProcessingReceipt<StoreEntitlements>()
        let synchronize = synchronize
        let entitlements = entitlements
        let task = Task.detached { [weak self] in
            let result: Result<StoreEntitlements, any Error>
            do {
                try await synchronize()
            } catch {
                await self?.complete(
                    id: id,
                    result: .failure(
                        RestoreCoordinatorFailure(
                            propagating: error,
                            reportsWhenAbandoned: true
                        ))
                )
                return
            }

            let refresh = await entitlements.reserve()
            do {
                result = .success(try await refresh.receipt.terminalValue())
            } catch {
                result = .failure(
                    RestoreCoordinatorFailure(
                        propagating: error,
                        reportsWhenAbandoned: refresh.role == .owner
                    ))
            }
            await self?.complete(id: id, result: result)
        }
        inFlight = InFlight(id: id, receipt: receipt, task: task)
        return RestoreReservation(receipt: receipt, role: .owner)
    }

    private func complete(
        id: UInt64,
        result: Result<StoreEntitlements, any Error>
    ) {
        guard let active = inFlight, active.id == id else { return }
        inFlight = nil
        switch result {
        case .success(let value):
            active.receipt.succeed(value)
        case .failure(let error):
            active.receipt.fail(error)
        }
    }

    isolated deinit {
        inFlight?.task.cancel()
    }
}
