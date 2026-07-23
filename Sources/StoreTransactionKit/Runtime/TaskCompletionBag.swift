import Foundation
import Synchronization

package final class TaskCompletionBag: Sendable {
    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])

    package init() {}

    package func insert(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks.withLock { $0[id] = task }
    }

    package func waitForAll() async {
        while true {
            let snapshot = tasks.withLock { Array($0) }
            guard !snapshot.isEmpty else { return }

            for (_, task) in snapshot {
                await task.value
            }

            tasks.withLock { tasks in
                for (id, _) in snapshot {
                    tasks.removeValue(forKey: id)
                }
            }
        }
    }

    package func cancel() {
        let snapshot = tasks.withLock { Array($0.values) }
        for task in snapshot {
            task.cancel()
        }
    }

    package func retainedTaskCount() -> Int {
        tasks.withLock(\.count)
    }
}
