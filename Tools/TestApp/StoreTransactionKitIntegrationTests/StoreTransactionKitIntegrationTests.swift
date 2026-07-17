import Foundation
import Observation
import StoreKit
import StoreKitTest
import StoreTransactionKit
import Testing

private enum Entitlement: String, Hashable, Sendable {
    case lifetime = "com.example.StoreTransactionKit.lifetime"
    case plus = "com.example.StoreTransactionKit.plus"
    case pro = "com.example.StoreTransactionKit.pro"
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct StoreTransactionKitIntegrationTests {
    @Test
    func externalPurchaseIsHandledAndFinishedBeforePublication() async throws {
        let session = try await makeTestSession()
        defer {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        let handlerStarted = TestSignal()
        let handlerRelease = TestSignal()
        let handlerCalls = TestSignal()

        let observedStore = ObservedStore(
            handleTransaction: { _ in
                await handlerCalls.send()
                await handlerStarted.send()
                try await handlerRelease.wait(for: 1)
            },
            reportFailure: { failure in
                Issue.record("Unexpected purchase failure: \(failure)")
            }
        )
        do {
            try await observedStore.waitForEntitlements([])

            _ = try await session.buyProduct(
                identifier: Entitlement.lifetime.rawValue
            )
            try await handlerStarted.wait(for: 1)

            #expect(observedStore.store.activeEntitlements == [])
            await handlerRelease.send()
            try await observedStore.waitForEntitlements([.lifetime])
            #expect(await handlerCalls.value() == 1)
        } catch {
            await handlerRelease.send()
            do {
                try await observedStore.close()
            } catch {
                Issue.record("Store cleanup failed: \(error)")
            }
            throw error
        }
        try await observedStore.close()

        let replayedHandlerCalls = TestSignal()
        try await withObservedStore(
            handleTransaction: { _ in
                await replayedHandlerCalls.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected post-finish failure: \(failure)")
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([.lifetime])
            #expect(await replayedHandlerCalls.value() == 0)
        }
    }

    @Test
    func directPurchaseIsProcessedAndPublishesPlus() async throws {
        try await withTestContext { context in
            let product = try await context.product(.plus)
            let appAccountToken = UUID()
            let result = try await product.purchase(
                options: [.appAccountToken(appAccountToken)]
            )

            let outcome = try await context.store.process(result)

            guard case .completed(let transaction) = outcome else {
                Issue.record("Expected a completed direct purchase.")
                return
            }
            #expect(transaction.productID == Entitlement.plus.rawValue)
            #expect(
                transaction.subscriptionGroupID
                    == "StoreTransactionKitSubscriptionGroup"
            )
            #expect(transaction.productType == .autoRenewable)
            #expect(transaction.environment == .xcode)
            #expect(transaction.offer == nil)
            #expect(!transaction.storefrontID.isEmpty)
            #expect(transaction.storefrontCountryCode == "USA")
            #expect(transaction.price == Decimal(string: "1.99"))
            #expect(transaction.currency?.identifier == "USD")
            #expect(transaction.originalID == transaction.id)
            #expect(transaction.originalPurchaseDate == transaction.purchaseDate)
            #expect(transaction.revocationDate == nil)
            #expect(transaction.revocationReason == nil)
            #expect(transaction.purchasedQuantity == 1)
            #expect(!transaction.isUpgraded)
            #expect(transaction.ownershipType == .purchased)
            #expect(transaction.reason == .purchase)
            #expect(transaction.appAccountToken == appAccountToken)
            #expect(!transaction.jwsRepresentation.isEmpty)
            #expect(context.store.activeEntitlements == [.plus])
        }
    }

    @Test
    func launchReconcilesAnExistingPurchase() async throws {
        try await withTestContext(preexistingSubscription: .plus) { context in
            #expect(context.store.activeEntitlements == [.plus])
        }
    }

    @Test
    func launchKeepsACancelledSubscriptionUntilItsExpiration() async throws {
        try await withTestContext(
            preexistingSubscription: .plus,
            preexistingPurchaseOptions: [
                .purchaseDate(.now, renewalBehavior: .cancelImmediately)
            ]
        ) { context in
            #expect(context.store.activeEntitlements == [.plus])
        }
    }

    @Test
    func launchExcludesAnAlreadyExpiredSubscription() async throws {
        let purchaseDate = try #require(
            Calendar(identifier: .gregorian).date(
                byAdding: .month,
                value: -2,
                to: .now
            )
        )

        try await withTestContext(
            preexistingSubscription: .plus,
            preexistingPurchaseOptions: [
                .purchaseDate(
                    purchaseDate,
                    renewalBehavior: .cancelImmediately
                )
            ],
            expectedEntitlements: []
        ) { context in
            #expect(context.store.activeEntitlements == [])
        }
    }

    @Test
    func unfinishedPurchaseReplaysUntilDurableHandlingSucceeds() async throws {
        let session = try await makeTestSession()
        defer {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        _ = try await session.buyProduct(identifier: Entitlement.plus.rawValue)

        let failedHandlerCalls = TestSignal()
        let launchDeliveryFailures = TestSignal()
        try await withObservedStore(
            handleTransaction: { _ in
                await failedHandlerCalls.send()
                throw DurableHandlingFailure()
            },
            reportFailure: { failure in
                switch failure.source {
                case .updates, .unfinished:
                    await launchDeliveryFailures.send()
                case .entitlementRefresh:
                    break
                default:
                    Issue.record("Unexpected launch failure: \(failure)")
                }
            }
        ) { observedStore in
            try await failedHandlerCalls.wait(for: 1)
            try await launchDeliveryFailures.wait(for: 1)
            try await observedStore.waitForStartupFailure()
            #expect(observedStore.store.activeEntitlements == nil)
        }

        let successfulHandlerCalls = TestSignal()
        try await withObservedStore(
            handleTransaction: { _ in
                await successfulHandlerCalls.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected retry failure: \(failure)")
            }
        ) { observedStore in
            try await successfulHandlerCalls.wait(for: 1)
            try await observedStore.waitForEntitlements([.plus])
        }

        let postFinishHandlerCalls = TestSignal()
        try await withObservedStore(
            handleTransaction: { _ in
                await postFinishHandlerCalls.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected post-finish failure: \(failure)")
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([.plus])
            #expect(await postFinishHandlerCalls.value() == 0)
        }
    }

    @Test
    func interruptedPurchaseCompletesAfterTheIssueIsResolved() async throws {
        try await withTestContext { context in
            context.session.interruptedPurchasesEnabled = true
            let product = try await context.product(.plus)
            let result = try await product.purchase()
            guard case .pending = result else {
                Issue.record("Expected the interrupted purchase to remain pending.")
                return
            }
            let interrupted = try #require(
                context.session.allTransactions().first {
                    $0.productIdentifier == Entitlement.plus.rawValue
                        && $0.hasPurchaseIssue
                }
            )

            try context.session.resolveIssueForTransaction(
                identifier: interrupted.identifier
            )

            try await context.waitForEntitlements([.plus])
        }
    }

    @Test
    func unverifiedUpdateIsReportedAndRemainsUnfinished() async throws {
        let session = try await makeTestSession()
        defer {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        let rejectedHandlerCalls = TestSignal()
        let updateFailures = TestSignal()

        try await withObservedStore(
            handleTransaction: { _ in
                await rejectedHandlerCalls.send()
            },
            reportFailure: { failure in
                if case .updates = failure.source {
                    await updateFailures.send()
                }
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([])
            try await session.setSimulatedError(
                .verification(.invalidSignature),
                forAPI: .verification
            )

            _ = try await session.buyProduct(identifier: Entitlement.plus.rawValue)
            try await updateFailures.wait(for: 1)

            #expect(await rejectedHandlerCalls.value() == 0)
            #expect(observedStore.store.activeEntitlements == [])
        }

        let unfinishedFailures = TestSignal()
        try await withObservedStore(
            handleTransaction: { _ in
                await rejectedHandlerCalls.send()
            },
            reportFailure: { failure in
                if case .unfinished = failure.source {
                    await unfinishedFailures.send()
                }
            }
        ) { _ in
            try await unfinishedFailures.wait(for: 1)
            #expect(await rejectedHandlerCalls.value() == 0)
        }
    }

    @Test
    func upgradeFromPlusToProPublishesOnlyPro() async throws {
        try await withTestContext { context in
            _ = try await context.session.buyProduct(identifier: Entitlement.plus.rawValue)
            try await context.waitForEntitlements([.plus])

            _ = try await context.session.buyProduct(identifier: Entitlement.pro.rawValue)

            try await context.waitForEntitlements([.pro])
            #expect(
                context.store.entitlements?.transactions.contains {
                    $0.productID == Entitlement.plus.rawValue && $0.isUpgraded
                } == true
            )
        }
    }

    @Test
    func downgradeFromProToPlusChangesAtRenewal() async throws {
        try await withTestContext { context in
            _ = try await context.session.buyProduct(identifier: Entitlement.pro.rawValue)
            try await context.waitForEntitlements([.pro])

            _ = try await context.session.buyProduct(identifier: Entitlement.plus.rawValue)

            let preRenewalEntitlements = try await context.store.refreshEntitlements()
            #expect(
                preRenewalEntitlements.transactions.map(\.productID)
                    == [Entitlement.pro.rawValue]
            )
            #expect(context.store.activeEntitlements == [.pro])
            try context.session.forceRenewalOfSubscription(
                productIdentifier: Entitlement.pro.rawValue
            )
            try await context.waitForEntitlements([.plus])
        }
    }

    @Test
    func cancellationKeepsPlusUntilExpirationThenRemovesIt() async throws {
        try await withTestContext { context in
            let transaction = try await context.session.buyProduct(
                identifier: Entitlement.plus.rawValue
            )
            try await context.waitForEntitlements([.plus])

            try context.session.disableAutoRenewForTransaction(
                identifier: UInt(transaction.id)
            )
            let cancelledTransaction = try #require(
                context.session.allTransactions().first {
                    $0.identifier == UInt(transaction.id)
                }
            )
            #expect(!cancelledTransaction.autoRenewingEnabled)

            let cancelledEntitlements = try await context.store.refreshEntitlements()
            #expect(
                cancelledEntitlements.transactions.map(\.productID)
                    == [Entitlement.plus.rawValue]
            )
            #expect(context.store.activeEntitlements == [.plus])

            try context.session.expireSubscription(
                productIdentifier: Entitlement.plus.rawValue
            )

            try await context.waitForEntitlements([])
        }
    }

    @Test
    func renewalPublishesTheNewTransactionLineage() async throws {
        try await withTestContext { context in
            let initial = try await context.session.buyProduct(
                identifier: Entitlement.plus.rawValue
            )
            try await context.waitForEntitlements([.plus])

            try context.session.forceRenewalOfSubscription(
                productIdentifier: Entitlement.plus.rawValue
            )

            let renewal = try await context.waitForTransaction(
                productID: Entitlement.plus.rawValue,
                excluding: initial.id
            )
            #expect(renewal.originalID == initial.originalID)
            #expect(renewal.reason == .renewal)
            #expect(context.store.activeEntitlements == [.plus])
        }
    }

    @Test
    func renewalWaitsForDurableHandlingBeforeStatusPublication() async throws {
        let session = try await makeTestSession()
        defer {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        let renewalHandlerStarted = TestSignal()
        let renewalHandlerRelease = TestSignal()
        let observedStore = ObservedStore(
            handleTransaction: { transaction in
                guard transaction.reason == .renewal else { return }
                await renewalHandlerStarted.send()
                try await renewalHandlerRelease.wait(for: 1)
            },
            reportFailure: { failure in
                Issue.record("Unexpected renewal failure: \(failure)")
            }
        )

        do {
            try await observedStore.waitForEntitlements([])
            let initial = try await session.buyProduct(
                identifier: Entitlement.plus.rawValue
            )
            try await observedStore.waitForEntitlements([.plus])

            try session.forceRenewalOfSubscription(
                productIdentifier: Entitlement.plus.rawValue
            )
            try await renewalHandlerStarted.wait(for: 1)

            #expect(
                observedStore.store.entitlements?.transactions.first?.id
                    == initial.id
            )
            await renewalHandlerRelease.send()
            let renewal = try await observedStore.waitForTransaction(
                productID: Entitlement.plus.rawValue,
                excluding: initial.id
            )
            #expect(renewal.reason == .renewal)
            #expect(renewal.originalID == initial.originalID)
        } catch {
            await renewalHandlerRelease.send()
            do {
                try await observedStore.close()
            } catch {
                Issue.record("Store cleanup failed: \(error)")
            }
            throw error
        }
        try await observedStore.close()

        let replayedHandlerCalls = TestSignal()
        try await withObservedStore(
            handleTransaction: { _ in
                await replayedHandlerCalls.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected post-renewal failure: \(failure)")
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([.plus])
            #expect(await replayedHandlerCalls.value() == 0)
        }
    }

    @Test
    func refundRemovesTheEntitlement() async throws {
        try await withTestContext { context in
            let transaction = try await context.session.buyProduct(
                identifier: Entitlement.plus.rawValue
            )
            try await context.waitForEntitlements([.plus])

            try context.session.refundTransaction(identifier: UInt(transaction.id))

            try await context.waitForEntitlements([])
        }
    }

    @Test
    func restoreWithNoPurchasesPublishesResolvedEmpty() async throws {
        try await withTestContext { context in
            let entitlements = try await context.store.restorePurchases()

            #expect(entitlements.transactions.isEmpty)
            #expect(context.store.activeEntitlements == [])
        }
    }

    @Test
    func restoreReturnsAnExistingEntitlement() async throws {
        try await withTestContext(preexistingSubscription: .plus) { context in
            let entitlements = try await context.store.restorePurchases()

            #expect(
                entitlements.transactions.map(\.productID)
                    == [Entitlement.plus.rawValue]
            )
            #expect(context.store.activeEntitlements == [.plus])
        }
    }

    @Test
    func restorePropagatesAppStoreSyncFailureAndCanRetry() async throws {
        try await withTestContext { context in
            let injectedFailure = SKTestFailures.AppStoreSync.generic(
                .networkError(URLError(.notConnectedToInternet))
            )
            try await context.session.setSimulatedError(
                injectedFailure,
                forAPI: .appStoreSync
            )
            #expect(
                await context.session.simulatedError(forAPI: .appStoreSync)
                    == injectedFailure
            )

            do {
                _ = try await context.store.restorePurchases()
                Issue.record("Expected restorePurchases() to fail.")
            } catch StoreKitError.networkError(let error) {
                #expect(error.code == .notConnectedToInternet)
            } catch {
                Issue.record("Unexpected restore error: \(error)")
            }

            try await context.session.setSimulatedError(
                nil,
                forAPI: .appStoreSync
            )
            #expect(
                await context.session.simulatedError(forAPI: .appStoreSync)
                    == nil
            )
            let entitlements = try await context.store.restorePurchases()
            #expect(entitlements.transactions.isEmpty)
            #expect(context.store.activeEntitlements == [])
        }
    }

    @Test
    func askToBuyApprovalArrivesThroughUpdates() async throws {
        try await withTestContext { context in
            context.session.askToBuyEnabled = true
            let product = try await context.product(.plus)
            let result = try await product.purchase()

            let outcome = try await context.store.process(result)

            guard case .pending = outcome else {
                Issue.record("Expected an Ask to Buy purchase to remain pending.")
                return
            }
            let pending = try #require(
                context.session.allTransactions().first {
                    $0.pendingAskToBuyConfirmation
                }
            )
            try context.session.approveAskToBuyTransaction(
                identifier: pending.identifier
            )
            try await context.waitForEntitlements([.plus])
        }
    }

    @Test
    func askToBuyDeclineDoesNotGrantAnEntitlement() async throws {
        try await withTestContext { context in
            context.session.askToBuyEnabled = true
            let product = try await context.product(.plus)
            let result = try await product.purchase()

            let outcome = try await context.store.process(result)

            guard case .pending = outcome else {
                Issue.record("Expected an Ask to Buy purchase to remain pending.")
                return
            }
            let pending = try #require(
                context.session.allTransactions().first {
                    $0.pendingAskToBuyConfirmation
                }
            )
            try context.session.declineAskToBuyTransaction(
                identifier: pending.identifier
            )

            let entitlements = try await context.store.restorePurchases()
            #expect(entitlements.transactions.isEmpty)
            #expect(context.store.activeEntitlements == [])
            #expect(
                context.session.allTransactions().allSatisfy {
                    !$0.pendingAskToBuyConfirmation
                }
            )
        }
    }

    private func withTestContext(
        preexistingSubscription: Entitlement? = nil,
        preexistingPurchaseOptions: Set<Product.PurchaseOption> = [],
        expectedEntitlements: Set<Entitlement>? = nil,
        _ body: (TestContext) async throws -> Void
    ) async throws {
        let context = try await TestContext(
            preexistingSubscription: preexistingSubscription,
            preexistingPurchaseOptions: preexistingPurchaseOptions,
            expectedEntitlements: expectedEntitlements
        )
        do {
            try await body(context)
        } catch {
            do {
                try await context.close()
            } catch {
                Issue.record("Store cleanup failed: \(error)")
            }
            throw error
        }
        try await context.close()
    }
}

@MainActor
private final class TestContext {
    let session: SKTestSession
    private let observedStore: ObservedStore

    var store: TransactionStore<Entitlement> {
        observedStore.store
    }

    init(
        preexistingSubscription: Entitlement? = nil,
        preexistingPurchaseOptions: Set<Product.PurchaseOption> = [],
        expectedEntitlements: Set<Entitlement>? = nil
    ) async throws {
        let session = try await makeTestSession()
        self.session = session
        if let preexistingSubscription {
            _ = try await session.buyProduct(
                identifier: preexistingSubscription.rawValue,
                options: preexistingPurchaseOptions
            )
        }

        let observedStore = ObservedStore(
            handleTransaction: { _ in },
            reportFailure: { error in
                Issue.record("Background transaction failure: \(error)")
            }
        )
        self.observedStore = observedStore
        let expected =
            expectedEntitlements
            ?? preexistingSubscription.map { [$0] }
            ?? []
        try await observedStore.waitForEntitlements(expected)
        #expect(store.startupError == nil)
    }

    func product(_ entitlement: Entitlement) async throws -> Product {
        try #require(
            try await Product.products(for: [entitlement.rawValue]).first
        )
    }

    func waitForEntitlements(
        _ expected: Set<Entitlement>
    ) async throws {
        try await observedStore.waitForEntitlements(expected)
    }

    func waitForTransaction(
        productID: String,
        excluding transactionID: UInt64
    ) async throws -> StoreTransactionSnapshot {
        try await observedStore.waitForTransaction(
            productID: productID,
            excluding: transactionID
        )
    }

    func close() async throws {
        defer {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        try await observedStore.close()
    }
}

@MainActor
private final class ObservedStore {
    let store: TransactionStore<Entitlement>
    let observation: TransactionStoreObservation

    init(
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        let store = TransactionStore<Entitlement>(
            handleTransaction: handleTransaction,
            reportFailure: reportFailure
        )
        self.store = store
        self.observation = TransactionStoreObservation(store: store)
    }

    func waitForEntitlements(_ expected: Set<Entitlement>) async throws {
        while true {
            let generation = observation.generation
            guard store.activeEntitlements != expected else { return }
            try await observation.waitForChange(after: generation)
        }
    }

    func waitForStartupFailure() async throws {
        while true {
            let generation = observation.generation
            guard store.startupError == nil else { return }
            try await observation.waitForChange(after: generation)
        }
    }

    func waitForTransaction(
        productID: String,
        excluding transactionID: UInt64
    ) async throws -> StoreTransactionSnapshot {
        while true {
            let generation = observation.generation
            if let transaction = store.entitlements?.transactions.first(where: {
                $0.productID == productID && $0.id != transactionID
            }) {
                return transaction
            }
            try await observation.waitForChange(after: generation)
        }
    }

    func close() async throws {
        observation.finish()
        try await store.close()
    }
}

@MainActor
private func withObservedStore(
    handleTransaction:
        @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
    reportFailure:
        @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void,
    _ body: (ObservedStore) async throws -> Void
) async throws {
    let observedStore = ObservedStore(
        handleTransaction: handleTransaction,
        reportFailure: reportFailure
    )
    do {
        try await body(observedStore)
    } catch {
        do {
            try await observedStore.close()
        } catch {
            Issue.record("Store cleanup failed: \(error)")
        }
        throw error
    }
    try await observedStore.close()
}

@MainActor
private final class TransactionStoreObservation {
    private weak var store: TransactionStore<Entitlement>?
    private let changes: AsyncStream<UInt64>
    private let continuation: AsyncStream<UInt64>.Continuation
    private(set) var generation: UInt64 = 0

    init(store: TransactionStore<Entitlement>) {
        let pair = AsyncStream<UInt64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.changes = pair.stream
        self.continuation = pair.continuation
        self.store = store
        observeNextChange()
    }

    func waitForChange(after observedGeneration: UInt64) async throws {
        guard observedGeneration == generation else { return }
        var iterator = changes.makeAsyncIterator()
        while observedGeneration == generation {
            try Task.checkCancellation()
            guard await iterator.next() != nil else {
                throw CancellationError()
            }
        }
    }

    func finish() {
        store = nil
        continuation.finish()
    }

    private func observeNextChange() {
        guard let store else { return }
        withObservationTracking {
            _ = store.entitlements
            _ = store.startupError
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.didChange()
            }
        }
    }

    private func didChange() {
        precondition(generation < .max)
        generation += 1
        observeNextChange()
        continuation.yield(generation)
    }
}

private actor TestSignal {
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func send() {
        count += 1
        let ready = waiters.filter { $0.value.target <= count }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func wait(for target: Int) async throws {
        guard count < target else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if count >= target {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(
                        target: target,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func value() -> Int {
        count
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

private struct DurableHandlingFailure: Error {}

private func makeTestSession() async throws -> SKTestSession {
    let configuration = try #require(
        Bundle(for: BundleToken.self).url(
            forResource: "StoreKitTest",
            withExtension: "storekit"
        )
    )
    let session = try SKTestSession(contentsOf: configuration)
    session.disableDialogs = true
    session.timeRate = .realTime
    session.resetToDefaultState()
    session.clearTransactions()
    try await StoreKitTestEnvironment.requireAvailable()
    return session
}

@MainActor
private enum StoreKitTestEnvironment {
    private static var isAvailable = false

    static func requireAvailable() async throws {
        guard !isAvailable else {
            return
        }
        _ = try #require(
            try await Product.products(
                for: [Entitlement.lifetime.rawValue]
            ).first,
            "The StoreKit test configuration is not active."
        )
        isAvailable = true
    }
}

private final class BundleToken {}
