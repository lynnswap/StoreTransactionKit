import Foundation

package struct ProcessingEnvelope<Value: Sendable>: Sendable {
    package let revision: Data
    package let value: Value
    package let finish: @Sendable () async -> Void

    package init(
        revision: Data,
        value: Value,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.revision = revision
        self.value = value
        self.finish = finish
    }
}
