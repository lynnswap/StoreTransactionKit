import Foundation
import Synchronization

package struct ProcessingReceiptWaiterCancellation: Error {}

package final class ProcessingReceipt<Value: Sendable>: Sendable {
    private typealias ReceiptResult = Result<Value, any Error>

    private final class Waiter: Sendable {
        private enum State {
            case idle
            case waiting(CheckedContinuation<ReceiptResult, Never>)
            case cancelled
            case terminal(ReceiptResult)
        }

        private let state = Mutex<State>(.idle)

        func value() async -> ReceiptResult {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> ReceiptResult? in
                    switch state {
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .cancelled:
                        return .failure(ProcessingReceiptWaiterCancellation())
                    case .terminal(let result):
                        return result
                    case .waiting:
                        preconditionFailure("A processing receipt waiter was awaited more than once.")
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        }

        func cancel() {
            let continuation = state.withLock { state -> CheckedContinuation<ReceiptResult, Never>? in
                switch state {
                case .idle:
                    state = .cancelled
                    return nil
                case .waiting(let continuation):
                    state = .cancelled
                    return continuation
                case .cancelled, .terminal:
                    return nil
                }
            }
            continuation?.resume(
                returning: .failure(ProcessingReceiptWaiterCancellation())
            )
        }

        func complete(_ result: ReceiptResult) {
            let continuation = state.withLock { state -> CheckedContinuation<ReceiptResult, Never>? in
                switch state {
                case .idle:
                    state = .terminal(result)
                    return nil
                case .waiting(let continuation):
                    state = .terminal(result)
                    return continuation
                case .cancelled:
                    return nil
                case .terminal:
                    preconditionFailure("A processing receipt waiter completed more than once.")
                }
            }
            continuation?.resume(returning: result)
        }
    }

    private enum State {
        case pending([UUID: Waiter])
        case terminal(ReceiptResult)
    }

    private enum Registration {
        case waiter(id: UUID, waiter: Waiter)
        case terminal(ReceiptResult)
    }

    private let state = Mutex<State>(.pending([:]))

    package init() {}

    package static func succeeded(_ value: Value) -> ProcessingReceipt<Value> {
        let receipt = ProcessingReceipt<Value>()
        receipt.complete(.success(value))
        return receipt
    }

    package static func failed(_ error: any Error) -> ProcessingReceipt<Value> {
        let receipt = ProcessingReceipt<Value>()
        receipt.complete(.failure(error))
        return receipt
    }

    package func value() async throws -> Value {
        guard !Task.isCancelled else {
            throw ProcessingReceiptWaiterCancellation()
        }

        switch registerWaiter() {
        case .terminal(let result):
            return try result.get()
        case .waiter(let id, let waiter):
            let result = await withTaskCancellationHandler {
                await waiter.value()
            } onCancel: {
                waiter.cancel()
                self.removeWaiter(id)
            }
            return try result.get()
        }
    }

    package func terminalValue() async throws -> Value {
        switch registerWaiter() {
        case .terminal(let result):
            return try result.get()
        case .waiter(_, let waiter):
            return try await waiter.value().get()
        }
    }

    package func succeed(_ value: Value) {
        complete(.success(value))
    }

    package func fail(_ error: any Error) {
        complete(.failure(error))
    }

    private func complete(_ result: ReceiptResult) {
        let waiters = state.withLock { state -> [Waiter] in
            guard case .pending(let waiters) = state else {
                preconditionFailure("A processing receipt completed more than once.")
            }
            state = .terminal(result)
            return Array(waiters.values)
        }
        for waiter in waiters {
            waiter.complete(result)
        }
    }

    private func registerWaiter() -> Registration {
        state.withLock { state in
            switch state {
            case .pending(var waiters):
                let id = UUID()
                let waiter = Waiter()
                waiters[id] = waiter
                state = .pending(waiters)
                return .waiter(id: id, waiter: waiter)
            case .terminal(let result):
                return .terminal(result)
            }
        }
    }

    private func removeWaiter(_ id: UUID) {
        state.withLock { state in
            guard case .pending(var waiters) = state else { return }
            waiters.removeValue(forKey: id)
            state = .pending(waiters)
        }
    }
}
