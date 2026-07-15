package actor RestoreCoordinator {
    private struct InFlight: Sendable {
        let id: UInt64
        let task: Task<StoreEntitlements, any Error>
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

    package func restore() async throws -> StoreEntitlements {
        if let inFlight {
            return try await inFlight.task.value
        }

        precondition(nextID < .max)
        nextID += 1
        let id = nextID
        let synchronize = synchronize
        let entitlements = entitlements
        let task = Task<StoreEntitlements, any Error> {
            try await synchronize()
            let receipt = await entitlements.reserve()
            return try await receipt.terminalValue()
        }
        inFlight = InFlight(id: id, task: task)

        do {
            let value = try await task.value
            clearInFlight(id: id)
            return value
        } catch {
            clearInFlight(id: id)
            throw error
        }
    }

    private func clearInFlight(id: UInt64) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }

    isolated deinit {
        inFlight?.task.cancel()
    }
}
