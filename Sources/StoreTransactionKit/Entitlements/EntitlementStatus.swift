/// The availability of the store's typed entitlement projection.
public enum EntitlementStatus: Sendable {
    /// The initial entitlement reconciliation has not completed.
    case loading

    /// No usable complete entitlement snapshot is available.
    ///
    /// The associated error explains why entitlement readiness failed.
    case failed(any Error)

    /// A complete live entitlement snapshot is available.
    ///
    /// Both raw and typed entitlement collections are authoritative in this
    /// state, including when they are empty.
    case ready

    /// App-supplied entitlements are authoritative instead of StoreKit state.
    case overridden
}
