import Foundation
import Synchronization

package final class TaskCompletionBag: Sendable {
    private struct State {
        var tasks: [UUID: Task<Void, Never>] = [:]
        var emptyWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    package init() {}

    package func insert(_ task: Task<Void, Never>) {
        let id = UUID()
        state.withLock { $0.tasks[id] = task }
        Task { [weak self] in
            await task.value
            self?.remove(id)
        }
    }

    package func waitForAll() async {
        await withCheckedContinuation { continuation in
            let isEmpty = state.withLock { state in
                guard !state.tasks.isEmpty else { return true }
                state.emptyWaiters.append(continuation)
                return false
            }
            if isEmpty {
                continuation.resume()
            }
        }
    }

    package func cancel() {
        let snapshot = state.withLock { Array($0.tasks.values) }
        for task in snapshot {
            task.cancel()
        }
    }

    package func retainedTaskCount() -> Int {
        state.withLock { $0.tasks.count }
    }

    private func remove(_ id: UUID) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.tasks.removeValue(forKey: id)
            guard state.tasks.isEmpty else { return [] }
            let waiters = state.emptyWaiters
            state.emptyWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
