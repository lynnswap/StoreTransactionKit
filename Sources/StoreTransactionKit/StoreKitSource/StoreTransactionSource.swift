import Foundation
import StoreKit

package enum StoreTransactionDelivery: Sendable {
    case verified(ProcessingEnvelope<StoreTransactionSnapshot>)
    case unverified(revision: Data, error: any Error)
}

package struct CurrentEntitlementQueryResult: Sendable {
    package struct VerificationFailure: Error, Sendable {
        package let revision: Data
        package let error: StoreTransactionVerificationError
    }

    package let snapshots: [StoreTransactionSnapshot]
    package let verificationFailures: [VerificationFailure]

    package init(
        snapshots: [StoreTransactionSnapshot],
        verificationFailures: [VerificationFailure]
    ) {
        self.snapshots = snapshots
        var revisions: Set<Data> = []
        self.verificationFailures = verificationFailures.filter {
            revisions.insert($0.revision).inserted
        }
    }

    package func replacingSubscriptionGroup(
        _ groupID: SubscriptionGroupID,
        with statuses: [(
            state: Product.SubscriptionInfo.RenewalState,
            transaction: Result<StoreTransactionSnapshot, VerificationFailure>
        )]
    ) -> Self {
        var snapshots = snapshots.filter {
            $0.subscriptionGroupID != groupID.rawValue
        }
        var verificationFailures = verificationFailures
        for status in statuses
        where status.state == .subscribed || status.state == .inGracePeriod {
            switch status.transaction {
            case .success(let transaction):
                snapshots.append(transaction)
            case .failure(let error):
                verificationFailures.append(error)
            }
        }
        return Self(
            snapshots: snapshots,
            verificationFailures: verificationFailures
        )
    }
}

package struct StoreTransactionSource: Sendable {
    package let runUpdates:
        @Sendable (
            @Sendable () -> FiniteOperationLease?,
            @Sendable (StoreTransactionDelivery) async -> Void
        ) async -> Void
    package let runSubscriptionStatusUpdates:
        @Sendable (
            @Sendable () -> FiniteOperationLease?,
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
                @Sendable () -> FiniteOperationLease?,
                @Sendable (StoreTransactionDelivery) async -> Void
            ) async -> Void,
        runSubscriptionStatusUpdates:
            @escaping @Sendable (
                @Sendable () -> FiniteOperationLease?,
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
        self.runSubscriptionStatusUpdates = runSubscriptionStatusUpdates
        self.currentEntitlements = currentEntitlements
        self.queryUnfinished = queryUnfinished
        self.history = history
        self.synchronize = synchronize
        self.purchaseDelivery = purchaseDelivery
    }
}
