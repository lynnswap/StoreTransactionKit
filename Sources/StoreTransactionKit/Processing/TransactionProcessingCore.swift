import Foundation

package enum TransactionProcessingDisposition: Equatable, Sendable {
    case finish
    case leaveUnfinished
}

package struct TransactionCausalResolutionClaim<Value: Sendable>: Sendable {
    package let value: Value
    package let reportingAuthority: DirectOperationReportingAuthority

    private let receipt: ProcessingReceipt<TransactionProcessingDisposition>
    private let finishSuccess: @Sendable () async -> TransactionProcessingDisposition
    private let finishFailure: @Sendable () async -> Void

    fileprivate init(
        value: Value,
        reportingAuthority: DirectOperationReportingAuthority,
        receipt: ProcessingReceipt<TransactionProcessingDisposition>,
        finishSuccess:
            @escaping @Sendable () async -> TransactionProcessingDisposition,
        finishFailure: @escaping @Sendable () async -> Void
    ) {
        self.value = value
        self.reportingAuthority = reportingAuthority
        self.receipt = receipt
        self.finishSuccess = finishSuccess
        self.finishFailure = finishFailure
    }

    package func succeed() async {
        let disposition = await finishSuccess()
        receipt.succeed(disposition)
    }

    package func fail(_ error: any Error) async {
        await finishFailure()
        receipt.fail(error)
    }
}

package struct ProcessingAcceptance<Value: Sendable>: Sendable {
    package enum Role: Equatable, Sendable {
        case owner
        case inFlightObserver
        case failedObserver
        case completedObserver
    }

    /// Completes after policy and the selected finish or leave action complete.
    package let receipt: ProcessingReceipt<TransactionProcessingDisposition>

    /// Completes after the exact revision's causal entitlement publication.
    package let causalReceipt: ProcessingReceipt<TransactionProcessingDisposition>
    package let role: Role
    package let reportingAuthority: DirectOperationReportingAuthority
    package let directBinding: DirectOperationObservation.Binding?

    private let claimCausalResolution: @Sendable () async -> TransactionCausalResolutionClaim<Value>?

    fileprivate init(
        receipt: ProcessingReceipt<TransactionProcessingDisposition>,
        causalReceipt: ProcessingReceipt<TransactionProcessingDisposition>,
        role: Role,
        reportingAuthority: DirectOperationReportingAuthority,
        directBinding: DirectOperationObservation.Binding?,
        claimCausalResolution:
            @escaping @Sendable () async
            -> TransactionCausalResolutionClaim<Value>?
    ) {
        self.receipt = receipt
        self.causalReceipt = causalReceipt
        self.role = role
        self.reportingAuthority = reportingAuthority
        self.directBinding = directBinding
        self.claimCausalResolution = claimCausalResolution
    }

    package func claimCausalResolutionIfOwner() async
        -> TransactionCausalResolutionClaim<Value>?
    {
        await claimCausalResolution()
    }
}

package actor TransactionProcessingCore<Value: Sendable> {
    private enum AttemptPhase: Sendable {
        case deciding
        case decisionFailed
        case resolved(TransactionProcessingDisposition)
    }

    private struct Attempt: Sendable {
        let id: UUID
        let value: Value
        let decisionReceipt: ProcessingReceipt<TransactionProcessingDisposition>
        let causalReceipt: ProcessingReceipt<TransactionProcessingDisposition>
        let reportingAuthority: DirectOperationReportingAuthority
        var causalResolutionClaimed: Bool
        var phase: AttemptPhase
    }

    private struct QueuedOperation: Sendable {
        let envelope: ProcessingEnvelope<Value>
        let attemptID: UUID
    }

    private let sessionID: UUID
    private let lifetime: TransactionStoreLifecycle?
    private let handle: @Sendable (Value) async throws -> TransactionProcessingDisposition
    private var queue: [QueuedOperation] = []
    private var inFlight: [Data: Attempt] = [:]
    private var failed: [Data: Attempt] = [:]
    private var completed = CompletedRevisionCache()
    private var worker: Task<Void, Never>?
    private var acceptsInput = true
    private var initialAttemptCompleted = false
    private nonisolated let workerCancellation = TaskCancellationBag()

    package init(
        sessionID: UUID = UUID(),
        lifetime: TransactionStoreLifecycle? = nil,
        handle:
            @escaping @Sendable (Value) async throws
            -> TransactionProcessingDisposition
    ) {
        self.sessionID = sessionID
        self.lifetime = lifetime
        self.handle = handle
    }

    package func accept(
        _ envelope: ProcessingEnvelope<Value>,
        directObservation: DirectOperationObservation? = nil
    ) -> ProcessingAcceptance<Value> {
        guard acceptsInput else {
            let error = StoreTransactionInternalError.inputClosed
            return ProcessingAcceptance(
                receipt: .failed(error),
                causalReceipt: .failed(error),
                role: .owner,
                reportingAuthority: DirectOperationReportingAuthority(),
                directBinding: nil,
                claimCausalResolution: { nil }
            )
        }
        if let attempt = inFlight[envelope.revision] {
            return acceptance(
                revision: envelope.revision,
                attempt: attempt,
                role: .inFlightObserver,
                directObservation: directObservation
            )
        }
        if let attempt = failed[envelope.revision] {
            return acceptance(
                revision: envelope.revision,
                attempt: attempt,
                role: .failedObserver,
                directObservation: directObservation,
                reportingAuthority: DirectOperationReportingAuthority()
            )
        }
        if completed.state(for: envelope.revision) == .satisfied {
            let reportingAuthority = DirectOperationReportingAuthority()
            return ProcessingAcceptance(
                receipt: .succeeded(.finish),
                causalReceipt: .succeeded(.finish),
                role: .completedObserver,
                reportingAuthority: reportingAuthority,
                directBinding: directObservation?.bind(
                    to: reportingAuthority
                ),
                claimCausalResolution: { nil }
            )
        }
        if completed.state(for: envelope.revision) == .needsRefresh {
            let attempt = makeAttempt(
                value: envelope.value,
                decisionReceipt: .succeeded(.finish),
                alreadyFinished: true
            )
            inFlight[envelope.revision] = attempt
            return acceptance(
                revision: envelope.revision,
                attempt: attempt,
                role: .completedObserver,
                directObservation: directObservation
            )
        }

        let attempt = makeAttempt(value: envelope.value)
        inFlight[envelope.revision] = attempt
        queue.append(
            QueuedOperation(
                envelope: envelope,
                attemptID: attempt.id
            )
        )
        let accepted = acceptance(
            revision: envelope.revision,
            attempt: attempt,
            role: .owner,
            directObservation: directObservation
        )
        startWorkerIfNeeded()
        return accepted
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

    package nonisolated func cancelSynchronously() {
        workerCancellation.cancel()
    }

    private func makeAttempt(
        value: Value,
        decisionReceipt:
            ProcessingReceipt<TransactionProcessingDisposition> =
            ProcessingReceipt<TransactionProcessingDisposition>(),
        alreadyFinished: Bool = false
    ) -> Attempt {
        Attempt(
            id: UUID(),
            value: value,
            decisionReceipt: decisionReceipt,
            causalReceipt:
                ProcessingReceipt<TransactionProcessingDisposition>(),
            reportingAuthority: DirectOperationReportingAuthority(),
            causalResolutionClaimed: false,
            phase: alreadyFinished ? .resolved(.finish) : .deciding
        )
    }

    private func acceptance(
        revision: Data,
        attempt: Attempt,
        role: ProcessingAcceptance<Value>.Role,
        directObservation: DirectOperationObservation?,
        reportingAuthority: DirectOperationReportingAuthority? = nil
    ) -> ProcessingAcceptance<Value> {
        let reportingAuthority = reportingAuthority ?? attempt.reportingAuthority
        return ProcessingAcceptance(
            receipt: attempt.decisionReceipt,
            causalReceipt: attempt.causalReceipt,
            role: role,
            reportingAuthority: reportingAuthority,
            directBinding: directObservation?.bind(to: reportingAuthority),
            claimCausalResolution: { [weak self] in
                guard let self else { return nil }
                return await self.claimCausalResolution(
                    revision: revision,
                    attemptID: attempt.id
                )
            }
        )
    }

    private func claimCausalResolution(
        revision: Data,
        attemptID: UUID
    ) -> TransactionCausalResolutionClaim<Value>? {
        let attempt: Attempt
        if var active = inFlight[revision], active.id == attemptID {
            guard !active.causalResolutionClaimed else { return nil }
            active.causalResolutionClaimed = true
            inFlight[revision] = active
            attempt = active
        } else {
            return nil
        }

        return TransactionCausalResolutionClaim(
            value: attempt.value,
            reportingAuthority: attempt.reportingAuthority,
            receipt: attempt.causalReceipt,
            finishSuccess: { [weak self] in
                guard let self else {
                    preconditionFailure(
                        "A causal resolution outlived its processing core."
                    )
                }
                return await self.finishCausalResolution(
                    revision: revision,
                    attemptID: attemptID,
                    succeeded: true
                )
            },
            finishFailure: { [weak self] in
                _ = await self?.finishCausalResolution(
                    revision: revision,
                    attemptID: attemptID,
                    succeeded: false
                )
            }
        )
    }

    private func finishCausalResolution(
        revision: Data,
        attemptID: UUID,
        succeeded: Bool
    ) -> TransactionProcessingDisposition {
        if let attempt = inFlight[revision], attempt.id == attemptID {
            precondition(attempt.causalResolutionClaimed)
            inFlight.removeValue(forKey: revision)
            if succeeded {
                guard case .resolved(let disposition) = attempt.phase else {
                    preconditionFailure(
                        "Causal resolution completed before transaction policy."
                    )
                }
                if disposition == .finish {
                    completed.insert(revision, state: .satisfied)
                }
                return disposition
            } else if case .decisionFailed = attempt.phase {
                failed[revision] = attempt
            }
            return .leaveUnfinished
        }
        if let attempt = failed[revision], attempt.id == attemptID {
            precondition(attempt.causalResolutionClaimed)
            return .leaveUnfinished
        }
        preconditionFailure("A causal resolution lost its processing attempt.")
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
            let operation = queue.removeFirst()
            guard
                let attempt = inFlight[operation.envelope.revision],
                attempt.id == operation.attemptID
            else {
                preconditionFailure("A queued transaction lost its processing attempt.")
            }
            do {
                let disposition =
                    try await StoreTransactionCallbackContext.$current.withValue(
                        StoreTransactionCallbackInvocation(
                            sessionID: sessionID,
                            callback: .transactionHandler
                        )
                    ) {
                        try await handle(operation.envelope.value)
                    }
                if disposition == .finish {
                    await operation.envelope.finish()
                    completed.insert(operation.envelope.revision)
                }
                guard
                    var finishedAttempt = inFlight[operation.envelope.revision],
                    finishedAttempt.id == operation.attemptID
                else {
                    preconditionFailure(
                        "A finished transaction lost its processing attempt."
                    )
                }
                finishedAttempt.phase = .resolved(disposition)
                inFlight[operation.envelope.revision] = finishedAttempt
                attempt.decisionReceipt.succeed(disposition)
            } catch {
                guard
                    var failedAttempt = inFlight[operation.envelope.revision],
                    failedAttempt.id == operation.attemptID
                else {
                    preconditionFailure(
                        "A failed transaction lost its processing attempt."
                    )
                }
                failedAttempt.phase = .decisionFailed
                inFlight[operation.envelope.revision] = failedAttempt
                attempt.decisionReceipt.fail(error)
            }
        }
        worker = nil
        workerCancellation.removeAll()
    }

    isolated deinit {
        worker?.cancel()
    }
}
