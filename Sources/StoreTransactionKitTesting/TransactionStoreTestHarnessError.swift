import Foundation
import StoreTransactionKit

/// An error produced while configuring or operating a transaction-store test harness.
public enum TransactionStoreTestHarnessError:
    LocalizedError,
    Sendable,
    Hashable
{
    /// The supplied group identifier differs from the catalog's group identifier.
    case subscriptionGroupMismatch(
        expected: SubscriptionGroupID,
        actual: SubscriptionGroupID
    )

    /// The supplied group declaration isn't the declaration that created the catalog.
    case subscriptionGroupTypeMismatch(
        subscriptionGroupID: SubscriptionGroupID
    )

    /// The supplied product isn't declared by the catalog's subscription group.
    case undeclaredProduct(
        productID: String,
        subscriptionGroupID: SubscriptionGroupID
    )

    /// The supplied product is already declared by the catalog's subscription group.
    case declaredProduct(
        productID: String,
        subscriptionGroupID: SubscriptionGroupID
    )

    /// The supplied value doesn't exactly match a snapshot registered by this harness.
    case unregisteredTransaction(transactionID: UInt64)

    /// The synthetic store doesn't provide the requested live StoreKit operation.
    case operationUnavailable(operation: StoreTransactionOperation)

    /// A localized description of the harness configuration or operation error.
    public var errorDescription: String? {
        switch self {
        case .subscriptionGroupMismatch(let expected, let actual):
            "Expected subscription group \(expected.rawValue), but received \(actual.rawValue)."

        case .subscriptionGroupTypeMismatch(let subscriptionGroupID):
            "The subscription group declaration for \(subscriptionGroupID.rawValue) did not create this catalog."

        case .undeclaredProduct(let productID, let subscriptionGroupID):
            "Product \(productID) is not declared by subscription group \(subscriptionGroupID.rawValue)."

        case .declaredProduct(let productID, let subscriptionGroupID):
            "Product \(productID) is already declared by subscription group \(subscriptionGroupID.rawValue)."

        case .unregisteredTransaction(let transactionID):
            "Transaction \(transactionID) does not exactly match a snapshot registered by this test harness."

        case .operationUnavailable(let operation):
            "The synthetic transaction store does not provide \(operation.description)."
        }
    }
}

private extension StoreTransactionOperation {
    var description: String {
        switch self {
        case .processPurchase:
            "purchase-result processing"
        case .refreshEntitlements:
            "entitlement refresh"
        case .history:
            "transaction history"
        case .restorePurchases:
            "purchase restoration"
        case .close:
            "closing"
        }
    }
}
