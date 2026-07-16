import Foundation
import StoreKit

/// An immutable projection of a transaction that StoreKit verified.
///
/// StoreTransactionKit creates snapshots only after StoreKit verification
/// succeeds. A snapshot never owns the underlying `Transaction` and
/// exposes no authority to finish it.
public struct StoreTransactionSnapshot: Sendable, Hashable {
    /// The identifier of this transaction revision's transaction.
    public let id: UInt64

    /// The identifier of the first transaction in the purchase lineage.
    public let originalID: UInt64

    /// The product identifier supplied in App Store Connect or StoreKit testing.
    public let productID: String

    /// The subscription group identifier, or `nil` for products outside a group.
    public let subscriptionGroupID: String?

    /// The StoreKit product type associated with the transaction.
    public let productType: Product.ProductType

    /// The App Store server environment that generated and signed the transaction.
    public let environment: AppStore.Environment

    /// The offer that applies to the transaction, when applicable.
    public let offer: Transaction.Offer?

    /// The Apple-defined identifier of the storefront associated with the transaction.
    public let storefrontID: String

    /// The ISO 3166-1 alpha-3 country code of the transaction's storefront.
    public let storefrontCountryCode: String

    /// The total price StoreKit recorded for the transaction, in units of ``currency``.
    ///
    /// Use App Store Connect reporting tools for financial and accounting purposes.
    public let price: Decimal?

    /// The currency of ``price``.
    public let currency: Locale.Currency?

    /// The date on which the customer purchased this transaction.
    public let purchaseDate: Date

    /// The purchase date of the first transaction in the purchase lineage.
    public let originalPurchaseDate: Date

    /// The entitlement expiration date, when the product expires.
    public let expirationDate: Date?

    /// The date StoreKit revoked or refunded the transaction, when applicable.
    public let revocationDate: Date?

    /// StoreKit's reason for revoking the transaction, when applicable.
    public let revocationReason: Transaction.RevocationReason?

    /// The quantity the customer purchased in this transaction.
    public let purchasedQuantity: Int

    /// A Boolean value that indicates whether an upgrade superseded the transaction.
    public let isUpgraded: Bool

    /// Whether the customer purchased the transaction or received it through sharing.
    public let ownershipType: Transaction.OwnershipType

    /// The reason StoreKit created this transaction, such as purchase or renewal.
    public let reason: Transaction.Reason

    /// The application account token associated with the purchase, when supplied.
    public let appAccountToken: UUID?

    /// The date the App Store signed this transaction revision.
    public let signedDate: Date

    /// The exact JWS Compact Serialization that StoreKit verified.
    ///
    /// StoreTransactionKit uses the UTF-8 bytes of this value as its
    /// process-local delivery revision. Consumers must not treat it as a secret
    /// or persist it as the sole business idempotency key.
    public let jwsRepresentation: String

    package init(
        id: UInt64,
        originalID: UInt64,
        productID: String,
        subscriptionGroupID: String?,
        productType: Product.ProductType,
        environment: AppStore.Environment,
        offer: Transaction.Offer?,
        storefrontID: String,
        storefrontCountryCode: String,
        price: Decimal?,
        currency: Locale.Currency?,
        purchaseDate: Date,
        originalPurchaseDate: Date,
        expirationDate: Date?,
        revocationDate: Date?,
        revocationReason: Transaction.RevocationReason?,
        purchasedQuantity: Int,
        isUpgraded: Bool,
        ownershipType: Transaction.OwnershipType,
        reason: Transaction.Reason,
        appAccountToken: UUID?,
        signedDate: Date,
        jwsRepresentation: String
    ) {
        self.id = id
        self.originalID = originalID
        self.productID = productID
        self.subscriptionGroupID = subscriptionGroupID
        self.productType = productType
        self.environment = environment
        self.offer = offer
        self.storefrontID = storefrontID
        self.storefrontCountryCode = storefrontCountryCode
        self.price = price
        self.currency = currency
        self.purchaseDate = purchaseDate
        self.originalPurchaseDate = originalPurchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.revocationReason = revocationReason
        self.purchasedQuantity = purchasedQuantity
        self.isUpgraded = isUpgraded
        self.ownershipType = ownershipType
        self.reason = reason
        self.appAccountToken = appAccountToken
        self.signedDate = signedDate
        self.jwsRepresentation = jwsRepresentation
    }
}
