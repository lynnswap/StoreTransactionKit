import StoreKit

/// A validated mapping from StoreKit products to app-defined entitlements.
public struct AutoRenewableSubscriptionCatalog<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    package let subscriptionGroupID: SubscriptionGroupID

    private let declaringGroupTypeID: ObjectIdentifier
    private let entitlementsByProductID: [Product.ID: Entitlement]

    /// Creates and validates a catalog from one auto-renewable subscription group.
    public init<Group>(_ groupType: Group.Type)
    where Group: AutoRenewableSubscriptionGroup<Entitlement> {
        let subscriptions = Group.subscriptions

        precondition(
            !subscriptions.isEmpty,
            "An auto-renewable subscription group must declare at least one product."
        )

        var entitlementsByProductID: [Product.ID: Entitlement] = [:]
        entitlementsByProductID.reserveCapacity(subscriptions.count)

        for subscription in subscriptions {
            let productID = subscription.id.rawValue

            precondition(
                !productID.isEmpty,
                "A subscription product identifier must not be empty."
            )
            precondition(
                entitlementsByProductID[productID] == nil,
                "A subscription product identifier must not be declared more than once: \(productID)"
            )

            entitlementsByProductID[productID] = subscription.entitlement
        }

        subscriptionGroupID = Group.id
        declaringGroupTypeID = ObjectIdentifier(groupType)
        self.entitlementsByProductID = entitlementsByProductID
    }

    package func activeEntitlements(
        in entitlements: StoreEntitlements
    ) throws -> Set<Entitlement> {
        var activeEntitlements: Set<Entitlement> = []

        for transaction in entitlements.transactions {
            switch try validatedTransaction(transaction) {
            case let .declared(entitlement):
                if !transaction.isUpgraded {
                    activeEntitlements.insert(entitlement)
                }

            case .retiredUpgraded, .unmanaged:
                continue
            }
        }

        return activeEntitlements
    }

    package func classification(
        of transaction: StoreTransactionSnapshot
    ) throws -> AutoRenewableSubscriptionClassification {
        switch try validatedTransaction(transaction) {
        case .declared, .retiredUpgraded:
            .managed

        case .unmanaged:
            .unmanaged
        }
    }

    package func isDeclared(by groupType: Any.Type) -> Bool {
        declaringGroupTypeID == ObjectIdentifier(groupType)
    }

    package func contains(productID: Product.ID) -> Bool {
        entitlementsByProductID[productID] != nil
    }

    private func validatedTransaction(
        _ transaction: StoreTransactionSnapshot
    ) throws -> ValidatedTransaction {
        if let entitlement = entitlementsByProductID[transaction.productID] {
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

            return .declared(entitlement)
        }

        guard transaction.subscriptionGroupID == subscriptionGroupID.rawValue else {
            return .unmanaged
        }

        guard transaction.isUpgraded else {
            throw AutoRenewableSubscriptionCatalogError.undeclaredProduct(
                productID: transaction.productID,
                subscriptionGroupID: subscriptionGroupID
            )
        }

        guard transaction.productType == .autoRenewable else {
            throw AutoRenewableSubscriptionCatalogError.productTypeMismatch(
                productID: transaction.productID,
                actual: transaction.productType
            )
        }

        return .retiredUpgraded
    }

    private enum ValidatedTransaction {
        case declared(Entitlement)
        case retiredUpgraded
        case unmanaged
    }
}
