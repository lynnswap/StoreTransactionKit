import Foundation
import Synchronization

package final class TaskCompletionBag: Sendable {
    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])

    package init() {}

    package func insert(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks.withLock { $0[id] = task }
        Task { [weak self] in
            await task.value
            self?.remove(id)
        }
    }

    package func waitForAll() async {
        let snapshot = tasks.withLock { Array($0.values) }
        for task in snapshot {
            await task.value
        }
        tasks.withLock { $0.removeAll(keepingCapacity: false) }
    }

    package func cancel() {
        let snapshot = tasks.withLock { Array($0.values) }
        for task in snapshot {
            task.cancel()
        }
    }

    package func retainedTaskCount() -> Int {
        tasks.withLock { $0.count }
    }

    private func remove(_ id: UUID) {
        _ = tasks.withLock { $0.removeValue(forKey: id) }
    }
}
