/// A product declaration and the app entitlement it grants.
public struct StoreSubscription<ProductID, Entitlement>: Sendable
where
    ProductID: RawRepresentable<String> & Hashable & Sendable,
    Entitlement: Hashable & Sendable
{
    /// The product identifier configured in App Store Connect.
    public let id: ProductID

    /// The app-defined entitlement granted by the product.
    public let entitlement: Entitlement

    /// Declares the entitlement granted by a subscription product.
    public init(
        _ id: ProductID,
        entitlement: Entitlement
    ) {
        self.id = id
        self.entitlement = entitlement
    }
}
