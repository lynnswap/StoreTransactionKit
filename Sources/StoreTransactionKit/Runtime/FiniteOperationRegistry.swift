import Synchronization

package final class FiniteOperationRegistry: Sendable {
    private struct State {
        var acceptsInput = true
        var count = 0
        var drainReceipt: ProcessingReceipt<Void>?
    }

    private let state = Mutex(State())

    package init() {}

    package func begin() -> FiniteOperationLease? {
        state.withLock { state in
            guard state.acceptsInput else { return nil }
            state.count += 1
            return FiniteOperationLease(registry: self)
        }
    }

    package func beginPair() -> FiniteOperationLeases? {
        state.withLock { state in
            guard state.acceptsInput else { return nil }
            state.count += 2
            return FiniteOperationLeases(
                work: FiniteOperationLease(registry: self),
                observer: FiniteOperationLease(registry: self)
            )
        }
    }

    package func stopAdmissionAndWait() async {
        let receipt = state.withLock { state -> ProcessingReceipt<Void>? in
            state.acceptsInput = false
            guard state.count > 0 else { return nil }
            if let receipt = state.drainReceipt { return receipt }
            let receipt = ProcessingReceipt<Void>()
            state.drainReceipt = receipt
            return receipt
        }
        if let receipt {
            _ = try? await receipt.terminalValue()
        }
    }

    fileprivate func end() {
        let receipt = state.withLock { state -> ProcessingReceipt<Void>? in
            precondition(state.count > 0)
            state.count -= 1
            guard state.count == 0 else { return nil }
            let receipt = state.drainReceipt
            state.drainReceipt = nil
            return receipt
        }
        receipt?.succeed(())
    }
}

package struct FiniteOperationLeases: Sendable {
    package let work: FiniteOperationLease
    package let observer: FiniteOperationLease
}

package final class FiniteOperationLease: Sendable {
    private let registry: FiniteOperationRegistry
    private let didEnd = Mutex(false)

    fileprivate init(registry: FiniteOperationRegistry) {
        self.registry = registry
    }

    package func end() {
        let shouldEnd = didEnd.withLock { didEnd in
            guard !didEnd else { return false }
            didEnd = true
            return true
        }
        if shouldEnd {
            registry.end()
        }
    }

    deinit {
        end()
    }
}
