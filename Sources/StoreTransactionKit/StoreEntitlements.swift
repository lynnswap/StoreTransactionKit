/// A complete, ordered projection of the current StoreKit entitlements.
public struct StoreEntitlements: Sendable, Equatable {
    /// Verified current entitlements in StoreTransactionKit's documented order.
    public let transactions: [StoreTransactionSnapshot]

    package init(transactions: [StoreTransactionSnapshot]) {
        self.transactions = transactions
    }
}

/// The initial entitlement publication completed by `start()`.
package struct StoreTransactionReadiness: Sendable, Equatable {
    let entitlements: StoreEntitlements

    package init(entitlements: StoreEntitlements) {
        self.entitlements = entitlements
    }
}
