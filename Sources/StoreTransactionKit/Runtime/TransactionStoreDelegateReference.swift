import Synchronization

package final class TransactionStoreDelegateReference: Sendable {
    private let delegate: Mutex<(any TransactionStoreDelegate)?>

    package init(_ delegate: (any TransactionStoreDelegate)?) {
        self.delegate = Mutex(delegate)
    }

    package func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        let delegate = delegate.withLock { $0 }
        return try await delegate?.decidePolicy(for: transaction) ?? .automatic
    }

    package func didFail(
        with failure: StoreTransactionBackgroundFailure
    ) async {
        let delegate = delegate.withLock { $0 }
        await delegate?.didFail(with: failure)
    }

    package func release() {
        delegate.withLock { $0 = nil }
    }
}
