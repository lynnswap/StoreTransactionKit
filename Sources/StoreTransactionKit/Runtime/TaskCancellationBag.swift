import Synchronization

package final class TaskCancellationBag: Sendable {
    private struct State {
        var tasks: [Task<Void, Never>] = []
        var isCancelled = false
    }

    private let state = Mutex(State())

    package init() {}

    package func insert(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            state.tasks.append(task)
            return state.isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    package func cancel() {
        let snapshot = state.withLock { state in
            state.isCancelled = true
            return state.tasks
        }
        for task in snapshot {
            task.cancel()
        }
    }

    package func removeAll() {
        state.withLock { $0.tasks.removeAll(keepingCapacity: false) }
    }
}
