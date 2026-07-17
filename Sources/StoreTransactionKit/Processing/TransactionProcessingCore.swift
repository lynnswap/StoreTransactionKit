import Foundation

package struct ProcessingAcceptance<Value: Sendable>: Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case inFlightObserver
        case failedObserver
        case completedObserver
    }

    package let receipt: ProcessingReceipt<Value>
    package let role: Role
    package let reportingAuthority: DirectOperationReportingAuthority
}

package actor TransactionProcessingCore<Value: Sendable> {
    private struct Attempt: Sendable {
        let receipt: ProcessingReceipt<Value>
        let reportingAuthority: DirectOperationReportingAuthority
    }

    private struct QueuedOperation: Sendable {
        let envelope: ProcessingEnvelope<Value>
        let attempt: Attempt
    }

    private let sessionID: UUID
    private let handle: @Sendable (Value) async throws -> Void
    private var queue: [QueuedOperation] = []
    private var inFlight: [Data: Attempt] = [:]
    private var failed: [Data: Attempt] = [:]
    private var completed = CompletedRevisionCache()
    private var worker: Task<Void, Never>?
    private var acceptsInput = true
    private var initialAttemptCompleted = false

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
                role: .owner,
                reportingAuthority: DirectOperationReportingAuthority()
            )
        }
        if completed.contains(envelope.revision) {
            return ProcessingAcceptance(
                receipt: .succeeded(envelope.value),
                role: .completedObserver,
                reportingAuthority: DirectOperationReportingAuthority()
            )
        }
        if let attempt = inFlight[envelope.revision] {
            return ProcessingAcceptance(
                receipt: attempt.receipt,
                role: .inFlightObserver,
                reportingAuthority: attempt.reportingAuthority
            )
        }
        if let attempt = failed[envelope.revision] {
            return ProcessingAcceptance(
                receipt: attempt.receipt,
                role: .failedObserver,
                reportingAuthority: attempt.reportingAuthority
            )
        }

        let attempt = Attempt(
            receipt: ProcessingReceipt<Value>(),
            reportingAuthority: DirectOperationReportingAuthority()
        )
        inFlight[envelope.revision] = attempt
        queue.append(QueuedOperation(envelope: envelope, attempt: attempt))
        startWorkerIfNeeded()
        return ProcessingAcceptance(
            receipt: attempt.receipt,
            role: .owner,
            reportingAuthority: attempt.reportingAuthority
        )
    }

    package func retryFailedTransactionsInNewAttempt() -> Bool {
        initialAttemptCompleted
    }

    package func beginTransactionAttempt() -> Bool {
        guard initialAttemptCompleted else {
            return false
        }
        failed.removeAll(keepingCapacity: true)
        return true
    }

    package func beginRetryAttempt() {
        failed.removeAll(keepingCapacity: true)
    }

    package func completeInitialAttempt() {
        initialAttemptCompleted = true
    }

    package func finishInputAndDrain() async {
        acceptsInput = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(queue.isEmpty)
        precondition(inFlight.isEmpty)
        failed.removeAll(keepingCapacity: false)
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
                operation.attempt.receipt.succeed(operation.envelope.value)
            } catch {
                inFlight.removeValue(forKey: operation.envelope.revision)
                failed[operation.envelope.revision] = operation.attempt
                operation.attempt.receipt.fail(error)
            }
        }
        worker = nil
    }

    isolated deinit {
        worker?.cancel()
    }
}
