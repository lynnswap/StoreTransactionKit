import StoreTransactionKit

/// Runs a scoped test with a ready-empty synthetic transaction store.
///
/// The store is closed and drained before this function returns or throws.
@MainActor
public func withTransactionStoreTestHarness<Entitlement, Result>(
    subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
    delegate: (any TransactionStoreDelegate)? = nil,
    _ operation:
        @MainActor (
            TransactionStoreTestHarness<Entitlement>
        ) async throws -> Result
) async throws -> Result
where Entitlement: Hashable & Sendable {
    let harness = try await TransactionStoreTestHarness.make(
        subscriptionCatalog: subscriptionCatalog,
        delegate: delegate
    )

    let operationResult: Swift.Result<Result, any Error>
    do {
        operationResult = .success(try await operation(harness))
    } catch {
        operationResult = .failure(error)
    }

    let closeResult: Swift.Result<Void, any Error>
    do {
        closeResult = .success(try await harness.store.close())
    } catch {
        closeResult = .failure(error)
    }

    switch operationResult {
    case .success(let result):
        try closeResult.get()
        return result
    case .failure(let error):
        throw error
    }
}
