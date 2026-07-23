import Foundation
import StoreKit

/// An inconsistency between a transaction snapshot and a subscription catalog.
public enum AutoRenewableSubscriptionCatalogError: LocalizedError, Sendable {
    /// A current product in the managed group has no catalog declaration.
    case undeclaredProduct(
        productID: Product.ID,
        subscriptionGroupID: SubscriptionGroupID
    )

    /// A catalog product isn't an auto-renewable subscription.
    case productTypeMismatch(
        productID: Product.ID,
        actual: Product.ProductType
    )

    /// A catalog product belongs to a different subscription group.
    case subscriptionGroupMismatch(
        productID: Product.ID,
        expected: SubscriptionGroupID,
        actual: String?
    )

    /// A localized description of the catalog inconsistency.
    public var errorDescription: String? {
        switch self {
        case let .undeclaredProduct(productID, subscriptionGroupID):
            "Product \(productID) is not declared in subscription group "
                + "\(subscriptionGroupID.rawValue)."

        case let .productTypeMismatch(productID, actual):
            "Product \(productID) has type \(actual); expected an "
                + "auto-renewable subscription."

        case let .subscriptionGroupMismatch(productID, expected, actual):
            "Product \(productID) belongs to subscription group "
                + (actual ?? "nil")
                + "; expected \(expected.rawValue)."
        }
    }
}

package struct StoreTransactionCatalogFailure: Error, Sendable {
    package let error: AutoRenewableSubscriptionCatalogError
}
