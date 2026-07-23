/// The availability of the store's typed entitlement projection.
public enum EntitlementStatus: Sendable {
    /// No entitlement readiness attempt has completed.
    case loading

    /// No usable complete entitlement snapshot is available.
    ///
    /// The associated error explains why entitlement readiness failed.
    case failed(any Error)

    /// A complete live entitlement snapshot is available.
    case ready

    /// App-supplied entitlements are authoritative instead of StoreKit state.
    case overridden
}
