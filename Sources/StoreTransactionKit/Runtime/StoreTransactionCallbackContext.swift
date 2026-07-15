import Foundation

package struct StoreTransactionCallbackInvocation: Sendable {
    package let sessionID: UUID
    package let callback: StoreTransactionCallback
}

package enum StoreTransactionCallbackContext {
    @TaskLocal package static var current: StoreTransactionCallbackInvocation?
}
