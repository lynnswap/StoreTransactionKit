import Synchronization

package final class TransactionStoreLifecycle: Sendable {
    private enum Phase: Sendable {
        case running
        case closing(ProcessingReceipt<Void>)
        case closed
    }

    private struct State: Sendable {
        var phase: Phase = .running
        var liveLease: LiveTransactionStoreLease?
    }

    private enum CloseAction: Sendable {
        case start(ProcessingReceipt<Void>)
        case join(ProcessingReceipt<Void>)
        case complete
    }

    private let state: Mutex<State>
    private let operations = FiniteOperationRegistry()
    private let producerIterations = FiniteOperationRegistry()
    private let didSeal = ProcessingReceipt<Void>()

    package init(liveLease: LiveTransactionStoreLease? = nil) {
        state = Mutex(State(liveLease: liveLease))
    }

    package func validateRunning() throws {
        switch phase() {
        case .running:
            return
        case .closing:
            throw StoreTransactionError.closing
        case .closed:
            throw StoreTransactionError.closed
        }
    }

    package func beginOperation() throws -> FiniteOperationLeases {
        try Task.checkCancellation()
        switch phase() {
        case .running:
            guard let leases = operations.beginPair() else {
                throw lifecycleError()
            }
            return leases
        case .closing:
            throw StoreTransactionError.closing
        case .closed:
            throw StoreTransactionError.closed
        }
    }

    package func beginProducerIteration() -> FiniteOperationLease? {
        guard case .running = phase() else { return nil }
        return producerIterations.begin()
    }

    package func close(
        shutdown: @escaping @Sendable () async -> Void
    ) async {
        let action = state.withLock { state -> CloseAction in
            switch state.phase {
            case .running:
                let receipt = ProcessingReceipt<Void>()
                state.phase = .closing(receipt)
                operations.seal()
                producerIterations.seal()
                return .start(receipt)
            case .closing(let receipt):
                return .join(receipt)
            case .closed:
                return .complete
            }
        }

        switch action {
        case .start(let receipt):
            didSeal.succeed(())
            Task.detached { [self] in
                await shutdown()
                finishClose(receipt: receipt)
            }
            _ = try? await receipt.terminalValue()
        case .join(let receipt):
            _ = try? await receipt.terminalValue()
        case .complete:
            return
        }
    }

    package func waitForOperations() async {
        await operations.waitForDrain()
    }

    package func waitForProducerIterations() async {
        await producerIterations.waitForDrain()
    }

    package func waitUntilSealed() async {
        _ = try? await didSeal.terminalValue()
    }

    package func sealSynchronously() {
        let shouldSeal = state.withLock { state in
            guard case .running = state.phase else { return false }
            state.phase = .closing(ProcessingReceipt<Void>())
            operations.seal()
            producerIterations.seal()
            return true
        }
        guard shouldSeal else { return }
        didSeal.succeed(())
    }

    private func phase() -> Phase {
        state.withLock(\.phase)
    }

    private func lifecycleError() -> StoreTransactionError {
        switch phase() {
        case .running, .closing:
            .closing
        case .closed:
            .closed
        }
    }

    private func finishClose(receipt: ProcessingReceipt<Void>) {
        let lease = state.withLock { state -> LiveTransactionStoreLease? in
            guard case .closing(let activeReceipt) = state.phase,
                activeReceipt === receipt
            else {
                preconditionFailure("Close completed without owning lifecycle shutdown.")
            }
            state.phase = .closed
            defer { state.liveLease = nil }
            return state.liveLease
        }
        lease?.release()
        receipt.succeed(())
    }

    deinit {
        state.withLock { state in
            state.liveLease?.release()
            state.liveLease = nil
        }
    }
}
