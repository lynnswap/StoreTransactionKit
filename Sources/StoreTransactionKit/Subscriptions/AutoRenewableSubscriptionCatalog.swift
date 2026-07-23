import StoreKit

/// A validated mapping from one auto-renewable subscription group to app entitlements.
///
/// The catalog treats ``AutoRenewableSubscriptionGroup/subscriptions`` as the
/// product identifiers known to this binary and validates StoreKit product type
/// and group metadata before publication.
public struct AutoRenewableSubscriptionCatalog<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    private struct Entry: Sendable {
        let entitlement: Entitlement
    }

    private let declaringGroupTypeID: ObjectIdentifier
    private let entriesByProductID: [Product.ID: Entry]

    /// The subscription group identifier configured in App Store Connect.
    public let subscriptionGroupID: SubscriptionGroupID

    /// The declared product identifiers in declaration order.
    ///
    /// Use this collection with StoreKit product-loading and merchandising APIs.
    public let productIDs: [Product.ID]

    /// Creates and validates a catalog from one auto-renewable subscription group.
    ///
    /// An empty declaration, empty product identifier, or duplicate raw product
    /// identifier is a programmer error. Multiple products may grant the same
    /// entitlement.
    public init<Group>(_ groupType: Group.Type)
    where Group: AutoRenewableSubscriptionGroup<Entitlement> {
        let subscriptions = Group.subscriptions

        precondition(
            !subscriptions.isEmpty,
            "An auto-renewable subscription group must declare at least one product."
        )

        var entriesByProductID: [Product.ID: Entry] = [:]
        entriesByProductID.reserveCapacity(subscriptions.count)
        var productIDs: [Product.ID] = []
        productIDs.reserveCapacity(subscriptions.count)

        for subscription in subscriptions {
            let productID = subscription.id.rawValue

            precondition(
                !productID.isEmpty,
                "A subscription product identifier must not be empty."
            )
            precondition(
                entriesByProductID[productID] == nil,
                "A subscription product identifier must not be declared more than once: \(productID)"
            )

            entriesByProductID[productID] = Entry(
                entitlement: subscription.entitlement
            )
            productIDs.append(productID)
        }

        subscriptionGroupID = Group.id
        self.productIDs = productIDs
        declaringGroupTypeID = ObjectIdentifier(groupType)
        self.entriesByProductID = entriesByProductID
    }

    /// Returns the app entitlement declared for a product identifier.
    ///
    /// The result is `nil` when the identifier isn't declared by this catalog.
    public func entitlement(for productID: Product.ID) -> Entitlement? {
        entriesByProductID[productID]?.entitlement
    }

    package func classification(
        of transaction: StoreTransactionSnapshot
    ) throws(AutoRenewableSubscriptionCatalogError)
        -> AutoRenewableSubscriptionClassification<Entitlement>
    {
        try validatedTransaction(transaction)
    }

    package func isDeclared(by groupType: Any.Type) -> Bool {
        declaringGroupTypeID == ObjectIdentifier(groupType)
    }

    package func contains(productID: Product.ID) -> Bool {
        entriesByProductID[productID] != nil
    }

    private func validatedTransaction(
        _ transaction: StoreTransactionSnapshot
    ) throws(AutoRenewableSubscriptionCatalogError) -> ValidatedTransaction {
        if let entry = entriesByProductID[transaction.productID] {
            guard transaction.productType == .autoRenewable else {
                throw AutoRenewableSubscriptionCatalogError.productTypeMismatch(
                    productID: transaction.productID,
                    actual: transaction.productType
                )
            }

            guard transaction.subscriptionGroupID == subscriptionGroupID.rawValue else {
                throw AutoRenewableSubscriptionCatalogError.subscriptionGroupMismatch(
                    productID: transaction.productID,
                    expected: subscriptionGroupID,
                    actual: transaction.subscriptionGroupID
                )
            }

            return .declared(entry.entitlement)
        }

        guard transaction.subscriptionGroupID == subscriptionGroupID.rawValue else {
            return .unmanaged
        }

        guard transaction.productType == .autoRenewable else {
            throw AutoRenewableSubscriptionCatalogError.productTypeMismatch(
                productID: transaction.productID,
                actual: transaction.productType
            )
        }

        return transaction.isUpgraded ? .retiredUpgraded : .unrecognized
    }

    private typealias ValidatedTransaction =
        AutoRenewableSubscriptionClassification<Entitlement>
}
