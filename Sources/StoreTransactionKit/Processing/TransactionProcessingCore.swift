import Foundation

package struct ProcessingAcceptance<Value: Sendable>: Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case inFlightObserver
        case completedObserver
    }

    package let receipt: ProcessingReceipt<Value>
    package let role: Role
}

package actor TransactionProcessingCore<Value: Sendable> {
    private struct QueuedOperation: Sendable {
        let envelope: ProcessingEnvelope<Value>
        let receipt: ProcessingReceipt<Value>
    }

    private let sessionID: UUID
    private let handle: @Sendable (Value) async throws -> Void
    private var queue: [QueuedOperation] = []
    private var inFlight: [Data: ProcessingReceipt<Value>] = [:]
    private var completed = CompletedRevisionCache()
    private var worker: Task<Void, Never>?
    private var acceptsInput = true

    package init(
        sessionID: UUID = UUID(),
        handle: @escaping @Sendable (Value) async throws -> Void
    ) {
        self.sessionID = sessionID
        self.handle = handle
    }

    package func accept(
        _ envelope: ProcessingEnvelope<Value>
    ) -> ProcessingAcceptance<Value> {
        guard acceptsInput else {
            return ProcessingAcceptance(
                receipt: .failed(StoreTransactionInternalError.inputClosed),
                role: .owner
            )
        }
        if completed.contains(envelope.revision) {
            return ProcessingAcceptance(
                receipt: .succeeded(envelope.value),
                role: .completedObserver
            )
        }
        if let receipt = inFlight[envelope.revision] {
            return ProcessingAcceptance(
                receipt: receipt,
                role: .inFlightObserver
            )
        }

        let receipt = ProcessingReceipt<Value>()
        inFlight[envelope.revision] = receipt
        queue.append(QueuedOperation(envelope: envelope, receipt: receipt))
        startWorkerIfNeeded()
        return ProcessingAcceptance(receipt: receipt, role: .owner)
    }

    package func finishInputAndDrain() async {
        acceptsInput = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(queue.isEmpty)
        precondition(inFlight.isEmpty)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task.detached { [weak self] in
            guard let self else { return }
            await self.drainQueue()
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let operation = queue.removeFirst()
            do {
                try await StoreTransactionCallbackContext.$current.withValue(
                    StoreTransactionCallbackInvocation(
                        sessionID: sessionID,
                        callback: .transactionHandler
                    )
                ) {
                    try await handle(operation.envelope.value)
                }
                await operation.envelope.finish()
                completed.insert(operation.envelope.revision)
                inFlight.removeValue(forKey: operation.envelope.revision)
                operation.receipt.succeed(operation.envelope.value)
            } catch {
                inFlight.removeValue(forKey: operation.envelope.revision)
                operation.receipt.fail(error)
            }
        }
        worker = nil
    }

    isolated deinit {
        worker?.cancel()
    }
}
