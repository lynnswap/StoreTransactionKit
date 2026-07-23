/// The identifier of an auto-renewable subscription group in App Store Connect.
public struct SubscriptionGroupID:
    RawRepresentable,
    Hashable,
    Sendable
{
    /// The identifier configured in App Store Connect.
    public let rawValue: String

    /// Creates a subscription group identifier from its App Store Connect value.
    public init(rawValue: String) {
        precondition(
            !rawValue.isEmpty,
            "A subscription group identifier must not be empty."
        )

        self.rawValue = rawValue
    }
}
