import Synchronization

package final class LiveTransactionStoreLease: Sendable {
    private static let isAcquired = Mutex(false)

    private let isReleased = Mutex(false)
    private let releaseReceipt = ProcessingReceipt<Void>()

    private init() {}

    package static func acquire() -> LiveTransactionStoreLease {
        isAcquired.withLock { isAcquired in
            precondition(
                !isAcquired,
                "Only one live TransactionStore may exist in a process."
            )
            isAcquired = true
        }
        return LiveTransactionStoreLease()
    }

    package func release() {
        let shouldRelease = isReleased.withLock { isReleased in
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        guard shouldRelease else { return }
        Self.isAcquired.withLock { isAcquired in
            precondition(isAcquired)
            isAcquired = false
        }
        releaseReceipt.succeed(())
    }

    package func waitUntilReleased() async {
        _ = try? await releaseReceipt.terminalValue()
    }

    deinit {
        release()
    }
}
