import Foundation

package actor UnrecognizedSubscriptionPolicyResolver<Entitlement>
where Entitlement: Hashable & Sendable {
    private typealias Policy = UnrecognizedSubscriptionPolicy<Entitlement>

    private enum State: Sendable {
        case pending(ProcessingReceipt<Policy>)
        case resolved(Policy)
    }

    private struct Request: Sendable {
        let revision: Data
        let transaction: StoreTransactionSnapshot
        let receipt: ProcessingReceipt<Policy>
    }

    private let sessionID: UUID
    private var delegate: (any UnrecognizedSubscriptionDelegate<Entitlement>)?
    private var states: [Data: State] = [:]
    private var queue: [Request] = []
    private var worker: Task<Void, Never>?
    private var acceptsInput = true
    private nonisolated let workerCancellation = TaskCancellationBag()

    package init(
        sessionID: UUID,
        delegate: (any UnrecognizedSubscriptionDelegate<Entitlement>)?
    ) {
        self.sessionID = sessionID
        self.delegate = delegate
    }

    package func policy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> UnrecognizedSubscriptionPolicy<Entitlement> {
        precondition(acceptsInput)
        let revision = Data(transaction.jwsRepresentation.utf8)
        let receipt: ProcessingReceipt<Policy>
        switch states[revision] {
        case .resolved(let policy):
            return policy
        case .pending(let pending):
            receipt = pending
        case nil:
            let pending = ProcessingReceipt<Policy>()
            states[revision] = .pending(pending)
            queue.append(
                Request(
                    revision: revision,
                    transaction: transaction,
                    receipt: pending
                )
            )
            receipt = pending
            startWorkerIfNeeded()
        }
        return try await receipt.terminalValue()
    }

    package func sealAndDrain() async {
        acceptsInput = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(queue.isEmpty)
        delegate = nil
        states.removeAll(keepingCapacity: false)
    }

    package nonisolated func cancelSynchronously() {
        workerCancellation.cancel()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.drainQueue()
        }
        worker = task
        workerCancellation.insert(task)
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            let delegate = delegate
            do {
                let policy = try await StoreTransactionCallbackContext.$current
                    .withValue(
                        StoreTransactionCallbackInvocation(
                            sessionID: sessionID,
                            callback: .transactionHandler
                        )
                    ) {
                        try await delegate?.decidePolicy(
                            forUnrecognizedSubscription: request.transaction
                        ) ?? .leaveUnfinished
                    }
                cache(policy, for: request.revision)
                request.receipt.succeed(policy)
            } catch {
                if case .pending(let receipt) = states[request.revision],
                    receipt === request.receipt
                {
                    states.removeValue(forKey: request.revision)
                }
                request.receipt.fail(error)
            }
        }
        worker = nil
        workerCancellation.removeAll()
    }

    private func cache(_ policy: Policy, for revision: Data) {
        states[revision] = .resolved(policy)
    }

    isolated deinit {
        worker?.cancel()
    }
}
