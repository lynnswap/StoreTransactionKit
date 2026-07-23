import Foundation

package struct CompletedRevisionCache {
    package enum State: Sendable {
        case needsRefresh
        case satisfied
    }

    private let capacity: Int
    private var insertionOrder: [Data] = []
    private var states: [Data: State] = [:]

    package init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    package func contains(_ revision: Data) -> Bool {
        states[revision] != nil
    }

    package func state(for revision: Data) -> State? {
        states[revision]
    }

    package mutating func insert(
        _ revision: Data,
        state: State = .needsRefresh
    ) {
        guard states[revision] == nil else {
            states[revision] = state
            return
        }
        states[revision] = state
        insertionOrder.append(revision)
        if insertionOrder.count > capacity {
            let evicted = insertionOrder.removeFirst()
            states.removeValue(forKey: evicted)
        }
    }
}
