import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Public policy and state primitives")
struct PublicPolicyStateTests {
    @Test("a failed entitlement status preserves its underlying error")
    func failedEntitlementStatusPreservesError() {
        let status = EntitlementStatus.failed(MarkerError(value: 7))

        guard case .failed(let error) = status else {
            Issue.record("Expected a failed entitlement status.")
            return
        }
        #expect(error as? MarkerError == MarkerError(value: 7))
    }

    @Test("the default delegate selects automatic handling")
    func defaultDelegatePolicy() async throws {
        let delegate: any TransactionStoreDelegate = DefaultDelegate()
        let transaction = makeSnapshot(id: 1)

        let policy = try await delegate.decidePolicy(for: transaction)
        #expect(policy == .automatic)

        await delegate.didFail(
            with: StoreTransactionBackgroundFailure(
                source: .updates,
                transactionID: transaction.id,
                productID: transaction.productID,
                underlyingError: MarkerError(value: 1)
            ))
    }

    @Test("an actor delegate can provide an app-owned finish decision")
    func actorDelegatePolicy() async throws {
        let delegate: any TransactionStoreDelegate = ActorDelegate()

        let policy = try await delegate.decidePolicy(
            for: makeSnapshot(id: 2)
        )

        #expect(policy == .finish)
    }

    @Test("completed action errors preserve recovery context")
    func completedActionErrorContext() {
        let transaction = makeSnapshot(id: 3)
        let error = StoreTransactionError.entitlementRefreshFailed(
            after: .finishedTransaction(transaction),
            underlyingError: MarkerError(value: 3)
        )

        guard
            case .entitlementRefreshFailed(let operation, let underlying) =
                error
        else {
            Issue.record("Expected a completed-action refresh failure.")
            return
        }
        #expect(
            operation
                == .finishedTransaction(transaction)
        )
        #expect(underlying as? MarkerError == MarkerError(value: 3))
    }

    @Test("an unhandled transaction records its StoreKit product metadata")
    func unhandledTransactionContext() {
        let error = StoreTransactionError.unhandledTransaction(
            productID: "consumable.product",
            productType: .consumable
        )

        guard
            case .unhandledTransaction(let productID, let productType) =
                error
        else {
            Issue.record("Expected an unhandled transaction failure.")
            return
        }
        #expect(productID == "consumable.product")
        #expect(productType == Product.ProductType.consumable)
    }
}

private struct MarkerError: Error, Sendable, Equatable {
    let value: Int
}

private final class DefaultDelegate: TransactionStoreDelegate {}

private actor ActorDelegate: TransactionStoreDelegate {
    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        .finish
    }
}
