import Foundation
import Synchronization

package final class TaskCompletionBag: Sendable {
    package struct Registration: Sendable {
        private let attachTask: @Sendable (Task<Void, Never>) -> Void
        private let completeTask: @Sendable () -> Void

        fileprivate init(
            attachTask: @escaping @Sendable (Task<Void, Never>) -> Void,
            completeTask: @escaping @Sendable () -> Void
        ) {
            self.attachTask = attachTask
            self.completeTask = completeTask
        }

        package func attach(_ task: Task<Void, Never>) {
            attachTask(task)
        }

        package func complete() {
            completeTask()
        }
    }

    private struct Entry: Sendable {
        var task: Task<Void, Never>?
        let completion: ProcessingReceipt<Void>
    }

    private struct State: Sendable {
        var entries: [UUID: Entry] = [:]
        var isCancelled = false
    }

    private let state = Mutex(State())

    package init() {}

    package func reserve() -> Registration {
        let id = UUID()
        let completion = ProcessingReceipt<Void>()
        state.withLock { state in
            state.entries[id] = Entry(
                task: nil,
                completion: completion
            )
        }
        return Registration(
            attachTask: { [weak self] task in
                self?.attach(task, to: id)
            },
            completeTask: { [weak self] in
                self?.complete(id)
            }
        )
    }

    package func waitForAll() async {
        while true {
            let snapshot = state.withLock {
                $0.entries.values.map(\.completion)
            }
            guard !snapshot.isEmpty else { return }

            for completion in snapshot {
                _ = try? await completion.terminalValue()
            }
        }
    }

    package func cancel() {
        let snapshot = state.withLock { state in
            state.isCancelled = true
            return state.entries.values.compactMap(\.task)
        }
        for task in snapshot {
            task.cancel()
        }
    }

    package func retainedTaskCount() -> Int {
        state.withLock(\.entries.count)
    }

    private func attach(
        _ task: Task<Void, Never>,
        to id: UUID
    ) {
        let shouldCancel = state.withLock { state in
            guard var entry = state.entries[id] else { return false }
            precondition(entry.task == nil, "A task completion registration was attached twice.")
            entry.task = task
            state.entries[id] = entry
            return state.isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func complete(_ id: UUID) {
        let completion = state.withLock {
            $0.entries.removeValue(forKey: id)?.completion
        }
        completion?.succeed(())
    }
}
