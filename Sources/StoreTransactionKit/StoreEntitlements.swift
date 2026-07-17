/// A complete, ordered projection of the current StoreKit entitlements.
public struct StoreEntitlements: Sendable, Equatable {
    /// Verified current entitlements in a stable order.
    ///
    /// Transactions are ordered by product identifier UTF-8 bytes ascending,
    /// then purchase date ascending, transaction identifier ascending, and
    /// exact JWS UTF-8 bytes ascending.
    public let transactions: [StoreTransactionSnapshot]

    package init(transactions: [StoreTransactionSnapshot]) {
        self.transactions = transactions
    }
}

/// The initial entitlement publication completed by `start()`.
package struct StoreTransactionReadiness: Sendable, Equatable {
    let entitlements: StoreEntitlements
    let refreshToken: UInt64

    package init(
        entitlements: StoreEntitlements,
        refreshToken: UInt64
    ) {
        self.entitlements = entitlements
        self.refreshToken = refreshToken
    }
}

package struct StoreTransactionReadinessFailure: Error {
    let refreshToken: UInt64
    let underlyingError: any Error
}
