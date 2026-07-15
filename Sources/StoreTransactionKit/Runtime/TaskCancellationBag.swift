import Synchronization

package final class TaskCancellationBag: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    package init() {}

    package func insert(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    package func cancel() {
        let snapshot = tasks.withLock { $0 }
        for task in snapshot {
            task.cancel()
        }
    }

    package func removeAll() {
        tasks.withLock { $0.removeAll(keepingCapacity: false) }
    }
}
