import StoreKit

package enum StoreTransactionDelivery: Sendable {
    case verified(ProcessingEnvelope<StoreTransactionSnapshot>)
    case unverified(any Error)
}

package struct CurrentEntitlementQueryResult: Sendable {
    package let snapshots: [StoreTransactionSnapshot]
    package let verificationFailures: [StoreTransactionVerificationError]

    package init(
        snapshots: [StoreTransactionSnapshot],
        verificationFailures: [StoreTransactionVerificationError]
    ) {
        self.snapshots = snapshots
        self.verificationFailures = verificationFailures
    }
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
    package let runSubscriptionStatusUpdates:
        @Sendable (
            @Sendable () async -> Void
        ) async -> Void
    package let currentEntitlements: @Sendable () async throws -> CurrentEntitlementQueryResult
    package let queryUnfinished: @Sendable () async -> [StoreTransactionDelivery]
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
        runSubscriptionStatusUpdates:
            @escaping @Sendable (
                @Sendable () async -> Void
            ) async -> Void,
        currentEntitlements:
            @escaping @Sendable () async throws
            -> CurrentEntitlementQueryResult,
        queryUnfinished:
            @escaping @Sendable () async -> [StoreTransactionDelivery],
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
        self.runSubscriptionStatusUpdates = runSubscriptionStatusUpdates
        self.currentEntitlements = currentEntitlements
        self.queryUnfinished = queryUnfinished
        self.history = history
        self.synchronize = synchronize
        self.purchaseDelivery = purchaseDelivery
    }
}
