package enum AutoRenewableSubscriptionClassification<Entitlement>:
    Equatable,
    Sendable
where Entitlement: Hashable & Sendable {
    case declared(Entitlement)
    case retiredUpgraded
    case unrecognized
    case unmanaged
}
