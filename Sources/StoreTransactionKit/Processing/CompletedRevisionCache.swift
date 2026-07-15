import Foundation

package struct CompletedRevisionCache {
    private let capacity: Int
    private var insertionOrder: [Data] = []
    private var membership: Set<Data> = []

    package init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    package func contains(_ revision: Data) -> Bool {
        membership.contains(revision)
    }

    package mutating func insert(_ revision: Data) {
        guard membership.insert(revision).inserted else { return }
        insertionOrder.append(revision)
        if insertionOrder.count > capacity {
            let evicted = insertionOrder.removeFirst()
            membership.remove(evicted)
        }
    }
}
