import Foundation
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

    @Test("store transaction errors provide localized descriptions")
    func localizedStoreTransactionErrors() {
        let transaction = makeSnapshot(
            id: 42,
            productID: "localized.product"
        )
        let underlyingDescription = "The entitlement query was unavailable."
        let unhandled = StoreTransactionError.unhandledTransaction(
            productID: "unhandled.product",
            productType: .consumable
        )
        let reentrant = StoreTransactionError.reentrantOperation(
            operation: .history
        )
        let unavailable = StoreTransactionError.operationUnavailableInOverride(
            operation: .restorePurchases
        )
        let refreshFailed = StoreTransactionError.entitlementRefreshFailed(
            after: .finishedTransaction(transaction),
            underlyingError: LocalizedMarkerError(
                description: underlyingDescription
            )
        )
        let errors: [StoreTransactionError] = [
            .closing,
            .closed,
            .unknownPurchaseResult,
            unhandled,
            reentrant,
            unavailable,
            refreshFailed,
        ]

        for error in errors {
            let localizedError: any LocalizedError = error
            #expect(localizedError.errorDescription?.isEmpty == false)
        }

        #expect(unhandled.errorDescription?.contains("unhandled.product") == true)
        #expect(
            unhandled.errorDescription?
                .contains(Product.ProductType.consumable.rawValue) == true
        )
        #expect(reentrant.errorDescription?.contains("history") == true)
        #expect(
            unavailable.errorDescription?.contains("purchase restoration") == true
        )
        #expect(refreshFailed.errorDescription?.contains("42") == true)
        #expect(
            refreshFailed.errorDescription?.contains("localized.product") == true
        )
        #expect(
            refreshFailed.errorDescription?.contains(underlyingDescription) == true
        )
        #expect(refreshFailed.recoverySuggestion?.isEmpty == false)
    }
}

private struct MarkerError: Error, Sendable, Equatable {
    let value: Int
}

private struct LocalizedMarkerError: LocalizedError, Sendable {
    let description: String

    var errorDescription: String? {
        description
    }
}

private final class DefaultDelegate: TransactionStoreDelegate {}

private actor ActorDelegate: TransactionStoreDelegate {
    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        .finish
    }
}
