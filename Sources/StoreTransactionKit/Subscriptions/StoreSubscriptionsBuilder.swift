/// Builds the subscription declarations for an auto-renewable subscription group.
@resultBuilder
public struct StoreSubscriptionsBuilder<ProductID, Entitlement>
where
    ProductID: RawRepresentable<String> & Hashable & Sendable,
    Entitlement: Hashable & Sendable
{
    public typealias Element =
        StoreSubscription<ProductID, Entitlement>

    /// Adds one subscription declaration to the group.
    public static func buildExpression(
        _ expression: Element
    ) -> Element {
        expression
    }

    /// Builds a nonempty subscription declaration.
    public static func buildBlock(
        _ first: Element,
        _ rest: Element...
    ) -> [Element] {
        [first] + rest
    }
}
