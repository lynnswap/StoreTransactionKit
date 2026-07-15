import StoreKit

package enum StoreTransactionDelivery: Sendable {
    case verified(ProcessingEnvelope<StoreTransactionSnapshot>)
    case unverified(any Error)
}

package struct StoreTransactionSource: Sendable {
    package let runUpdates:
        @Sendable (
            @Sendable (StoreTransactionDelivery) async -> Void
        ) async -> Void
    package let runUnfinished:
        @Sendable (
            @Sendable (StoreTransactionDelivery) async -> Void
        ) async -> Void
    package let currentEntitlements: @Sendable () async throws -> [StoreTransactionSnapshot]
    package let history: @Sendable (Product.ID) async throws -> [StoreTransactionSnapshot]
    package let synchronize: @Sendable () async throws -> Void
    package let purchaseDelivery: @Sendable (VerificationResult<Transaction>) -> StoreTransactionDelivery

    package init(
        runUpdates:
            @escaping @Sendable (
                @Sendable (StoreTransactionDelivery) async -> Void
            ) async -> Void,
        runUnfinished:
            @escaping @Sendable (
                @Sendable (StoreTransactionDelivery) async -> Void
            ) async -> Void,
        currentEntitlements:
            @escaping @Sendable () async throws
            -> [StoreTransactionSnapshot],
        history:
            @escaping @Sendable (Product.ID) async throws
            -> [StoreTransactionSnapshot],
        synchronize: @escaping @Sendable () async throws -> Void,
        purchaseDelivery:
            @escaping @Sendable (
                VerificationResult<Transaction>
            ) -> StoreTransactionDelivery
    ) {
        self.runUpdates = runUpdates
        self.runUnfinished = runUnfinished
        self.currentEntitlements = currentEntitlements
        self.history = history
        self.synchronize = synchronize
        self.purchaseDelivery = purchaseDelivery
    }
}
