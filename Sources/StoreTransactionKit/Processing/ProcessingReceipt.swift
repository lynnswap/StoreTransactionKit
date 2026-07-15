import Foundation
import Synchronization

package final class ProcessingReceipt<Value: Sendable>: Sendable {
    private typealias ReceiptResult = Result<Value, any Error>

    private enum State {
        case pending([UUID: CheckedContinuation<ReceiptResult, Never>])
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
        let waiterID = UUID()
        let cancellation = Mutex(false)

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let wasCancelled = cancellation.withLock { $0 }
                let immediate = state.withLock { state -> ReceiptResult? in
                    if wasCancelled {
                        return .failure(CancellationError())
                    }
                    switch state {
                    case .pending(var waiters):
                        waiters[waiterID] = continuation
                        state = .pending(waiters)
                        return nil
                    case .terminal(let result):
                        return result
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
            let continuation = state.withLock { state -> CheckedContinuation<ReceiptResult, Never>? in
                guard case .pending(var waiters) = state else { return nil }
                let continuation = waiters.removeValue(forKey: waiterID)
                state = .pending(waiters)
                return continuation
            }
            continuation?.resume(returning: .failure(CancellationError()))
        }

        return try result.get()
    }

    package func terminalValue() async throws -> Value {
        let result = await withCheckedContinuation { continuation in
            let waiterID = UUID()
            let immediate = state.withLock { state -> ReceiptResult? in
                switch state {
                case .pending(var waiters):
                    waiters[waiterID] = continuation
                    state = .pending(waiters)
                    return nil
                case .terminal(let result):
                    return result
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        return try result.get()
    }

    package func succeed(_ value: Value) {
        complete(.success(value))
    }

    package func fail(_ error: any Error) {
        complete(.failure(error))
    }

    private func complete(_ result: ReceiptResult) {
        let continuations = state.withLock { state -> [CheckedContinuation<ReceiptResult, Never>] in
            guard case .pending(let waiters) = state else {
                preconditionFailure("A processing receipt completed more than once.")
            }
            state = .terminal(result)
            return Array(waiters.values)
        }
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}
