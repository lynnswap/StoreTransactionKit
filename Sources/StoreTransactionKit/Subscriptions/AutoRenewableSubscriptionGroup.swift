/// A typed declaration of one App Store auto-renewable subscription group.
///
/// The group binds typed product identifiers to app-domain entitlement values.
/// StoreKit continues to own subscription duration and upgrade or downgrade
/// ordering; the entitlement type describes access in the app.
public protocol AutoRenewableSubscriptionGroup<Entitlement> {
    /// The app-defined access value granted by the group's products.
    associatedtype Entitlement: Hashable & Sendable

    /// A typed product identifier declared by this group.
    associatedtype
        ProductID:
            RawRepresentable<String> & Hashable & Sendable

    /// The group's identifier in App Store Connect.
    static var id: SubscriptionGroupID { get }

    /// The complete set of declared products and the entitlement each one grants.
    @StoreSubscriptionsBuilder<
        Self.ProductID,
        Self.Entitlement
    >
    static var subscriptions: Self.StoreSubscriptions { get }
}

public extension AutoRenewableSubscriptionGroup {
    /// The concrete collection produced by the subscription builder.
    typealias StoreSubscriptions =
        [StoreSubscription<ProductID, Entitlement>]
}
