package struct RestoreReservation<Entitlement>: Sendable
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

package struct RestoreCoordinatorFailure: Error, Sendable {
    package let underlyingError: any Error
    package let synchronized: Bool
    package let reportsWhenAbandoned: Bool

    package init(
        propagating error: any Error,
        synchronized: Bool,
        reportsWhenAbandoned: Bool
    ) {
        let propagation = StoreTransactionFailurePropagation(error)
        underlyingError = propagation.underlyingError
        self.synchronized = synchronized
        self.reportsWhenAbandoned =
            reportsWhenAbandoned && !propagation.hasReportingOwner
    }
}

package actor RestoreCoordinator<Entitlement>
where Entitlement: Hashable & Sendable {
    private struct InFlight: Sendable {
        let id: UInt64
        let receipt: ProcessingReceipt<EntitlementPublication<Entitlement>>
        let reportingAuthority: DirectOperationReportingAuthority
        let task: Task<Void, Never>
    }

    private let synchronize: @Sendable () async throws -> Void
    private let entitlements: EntitlementRefreshCoordinator<Entitlement>
    private var nextID: UInt64 = 0
    private var inFlight: InFlight?
    private nonisolated let taskCancellation = TaskCancellationBag()

    package init(
        synchronize: @escaping @Sendable () async throws -> Void,
        entitlements: EntitlementRefreshCoordinator<Entitlement>
    ) {
        self.synchronize = synchronize
        self.entitlements = entitlements
    }

    package func reserve(
        retryFailedTransactions: Bool = true,
        directObservation: DirectOperationObservation? = nil
    ) -> RestoreReservation<Entitlement> {
        if let inFlight {
            return RestoreReservation(
                receipt: inFlight.receipt,
                role: .observer,
                reportingAuthority: inFlight.reportingAuthority,
                directBinding: directObservation?.bind(
                    to: inFlight.reportingAuthority
                )
            )
        }

        precondition(nextID < .max)
        nextID += 1
        let id = nextID
        let receipt = ProcessingReceipt<EntitlementPublication<Entitlement>>()
        let reportingAuthority = DirectOperationReportingAuthority()
        let directBinding = directObservation?.bind(to: reportingAuthority)
        let synchronize = synchronize
        let entitlements = entitlements
        let task = Task.detached { [weak self] in
            do {
                try await synchronize()
            } catch {
                await self?.complete(
                    id: id,
                    result: .failure(
                        RestoreCoordinatorFailure(
                            propagating: error,
                            synchronized: false,
                            reportsWhenAbandoned: true
                        )
                    )
                )
                return
            }

            let refresh = await entitlements.reserve(
                retryFailedTransactions: retryFailedTransactions,
                reportingAuthority: reportingAuthority
            )
            do {
                await self?.complete(
                    id: id,
                    result: .success(
                        try await refresh.receipt.terminalValue()
                    )
                )
            } catch {
                await self?.complete(
                    id: id,
                    result: .failure(
                        RestoreCoordinatorFailure(
                            propagating: error,
                            synchronized: true,
                            reportsWhenAbandoned: refresh.role == .owner
                        )
                    )
                )
            }
        }
        taskCancellation.insert(task)
        inFlight = InFlight(
            id: id,
            receipt: receipt,
            reportingAuthority: reportingAuthority,
            task: task
        )
        return RestoreReservation(
            receipt: receipt,
            role: .owner,
            reportingAuthority: reportingAuthority,
            directBinding: directBinding
        )
    }

    private func complete(
        id: UInt64,
        result: Result<EntitlementPublication<Entitlement>, any Error>
    ) {
        guard let active = inFlight, active.id == id else { return }
        inFlight = nil
        switch result {
        case .success(let value):
            active.receipt.succeed(value)
        case .failure(let error):
            active.receipt.fail(error)
        }
        taskCancellation.removeAll()
    }

    package nonisolated func cancelSynchronously() {
        taskCancellation.cancel()
    }

    isolated deinit {
        inFlight?.task.cancel()
    }
}
