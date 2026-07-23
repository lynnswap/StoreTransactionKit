import Foundation
import Observation
import StoreKit
import StoreKitTest
import StoreTransactionKit
import Testing
#if os(visionOS)
    import UIKit
#endif

private enum SubscriptionEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

private enum Plans: AutoRenewableSubscriptionGroup<SubscriptionEntitlement> {
    static let id = SubscriptionGroupID(
        rawValue: "StoreTransactionKitSubscriptionGroup"
    )

    enum ProductID: String, CaseIterable, Sendable {
        case tier1_Monthly = "com.example.StoreTransactionKit.tier1.monthly"
        case tier1_Yearly = "com.example.StoreTransactionKit.tier1.yearly"
        case tier2_Monthly = "com.example.StoreTransactionKit.tier2.monthly"
        case tier2_Yearly = "com.example.StoreTransactionKit.tier2.yearly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.tier1_Monthly, entitlement: .tier1)
        StoreSubscription(.tier1_Yearly, entitlement: .tier1)
        StoreSubscription(.tier2_Monthly, entitlement: .tier2)
        StoreSubscription(.tier2_Yearly, entitlement: .tier2)
    }
}

private let subscriptionCatalog = AutoRenewableSubscriptionCatalog(Plans.self)
private let externalSubscriptionProductID =
    "com.example.StoreTransactionKit.external.monthly"

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
            decidePolicy: { _ in
                await handlerCalls.send()
                await handlerStarted.send()
                try await handlerRelease.wait(for: 1)
                return .finish
            },
            didFail: { failure in
                Issue.record("Unexpected purchase failure: \(failure)")
            }
        )
        var purchaseTask: Task<StoreKit.Transaction, any Error>?
        do {
            try await observedStore.waitForEntitlements([])

            let task = Task { @MainActor in
                try await session.buyProduct(
                    identifier: externalSubscriptionProductID
                )
            }
            purchaseTask = task
            try await handlerStarted.wait(for: 1)

            #expect(observedStore.store.activeEntitlements == [])
            await handlerRelease.send()
            _ = try await task.value
            #expect(await handlerCalls.value() == 1)
            if #available(iOS 27.0,
            tvOS 27.0,
            watchOS 27.0,
            visionOS 27.0,
            *) {
                _ = try await observedStore.waitForTransaction(
                    productID: externalSubscriptionProductID,
                    excluding: 0
                )
            } else {
                _ = try await observedStore.store.refreshEntitlements()
            }
            #expect(
                observedStore.store.entitlements?.transactions.map(\.productID)
                    == [externalSubscriptionProductID]
            )
            #expect(observedStore.store.activeEntitlements == [])
        } catch {
            purchaseTask?.cancel()
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
            decidePolicy: { _ in
                await replayedHandlerCalls.send()
                return .finish
            },
            didFail: { failure in
                Issue.record("Unexpected post-finish failure: \(failure)")
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([])
            guard case .ready = observedStore.store.entitlementStatus else {
                Issue.record("The replay store did not reach ready state.")
                return
            }
            #expect(await replayedHandlerCalls.value() == 0)
            if #available(iOS 27.0,
            tvOS 27.0,
            watchOS 27.0,
            visionOS 27.0,
            *) {
                _ = try await observedStore.waitForTransaction(
                    productID: externalSubscriptionProductID,
                    excluding: 0
                )
            } else {
                _ = try await observedStore.store.refreshEntitlements()
            }
            #expect(
                observedStore.store.entitlements?.transactions.map(\.productID)
                    == [externalSubscriptionProductID]
            )
            #expect(observedStore.store.activeEntitlements == [])
            #expect(await replayedHandlerCalls.value() == 0)
        }
    }

    @Test
    func directPurchaseIsProcessedAndPublishesTier1() async throws {
        try await withTestContext { context in
            let product = try await context.product(.tier1_Monthly)
            let appAccountToken = UUID()
            let result = try await purchase(
                product,
                options: [.appAccountToken(appAccountToken)]
            )

            let outcome = try await context.store.process(result)

            guard case .completed(let transaction) = outcome else {
                Issue.record("Expected a completed direct purchase.")
                return
            }
            #expect(transaction.productID == Plans.ProductID.tier1_Monthly.rawValue)
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
            #expect(context.store.activeEntitlements == [.tier1])
        }
    }

    @Test
    func launchMapsEverySubscriptionProduct() async throws {
        for productID in Plans.ProductID.allCases {
            try await withTestContext(preexistingSubscription: productID) { context in
                switch productID {
                case .tier1_Monthly, .tier1_Yearly:
                    #expect(context.store.activeEntitlements == [.tier1])
                case .tier2_Monthly, .tier2_Yearly:
                    #expect(context.store.activeEntitlements == [.tier2])
                }
            }
        }
    }

    @Test
    func launchKeepsACancelledSubscriptionUntilItsExpiration() async throws {
        try await withTestContext(
            preexistingSubscription: .tier1_Monthly,
            preexistingPurchaseOptions: [
                .purchaseDate(.now, renewalBehavior: .cancelImmediately)
            ]
        ) { context in
            #expect(context.store.activeEntitlements == [.tier1])
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
            preexistingSubscription: .tier1_Monthly,
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
        _ = try await session.buyProduct(
            identifier: Plans.ProductID.tier1_Monthly.rawValue
        )

        let failedHandlerCalls = TestSignal()
        let launchDeliveryFailures = TestSignal()
        try await withObservedStore(
            decidePolicy: { _ in
                await failedHandlerCalls.send()
                throw DurableHandlingFailure()
            },
            didFail: { failure in
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
            decidePolicy: { _ in
                await successfulHandlerCalls.send()
                return .finish
            },
            didFail: { failure in
                Issue.record("Unexpected retry failure: \(failure)")
            }
        ) { observedStore in
            try await successfulHandlerCalls.wait(for: 1)
            try await observedStore.waitForEntitlements([.tier1])
        }

        let postFinishHandlerCalls = TestSignal()
        try await withObservedStore(
            decidePolicy: { _ in
                await postFinishHandlerCalls.send()
                return .finish
            },
            didFail: { failure in
                Issue.record("Unexpected post-finish failure: \(failure)")
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([.tier1])
            #expect(await postFinishHandlerCalls.value() == 0)
        }
    }

    @Test
    func interruptedPurchaseCompletesAfterTheIssueIsResolved() async throws {
        try await withTestContext { context in
            context.session.interruptedPurchasesEnabled = true
            let interrupted: SKTestTransaction
            if #available(iOS 27.0,
            tvOS 27.0,
            watchOS 27.0,
            visionOS 27.0,
            *) {
                let transaction = try await context.session.buyProduct(
                    identifier: Plans.ProductID.tier1_Monthly.rawValue
                )
                interrupted = try #require(
                    context.session.allTransactions().first {
                        $0.identifier == Int(transaction.id)
                    }
                )
            } else {
                let product = try await context.product(.tier1_Monthly)
                let result = try await purchase(product)
                let outcome = try await context.store.process(result)
                guard case .pending = outcome else {
                    Issue.record(
                        "Expected the interrupted purchase to remain pending."
                    )
                    return
                }
                interrupted = try #require(
                    context.session.allTransactions().first {
                        $0.productIdentifier
                            == Plans.ProductID.tier1_Monthly.rawValue
                            && $0.hasPurchaseIssue
                    }
                )
            }
            #expect(interrupted.hasPurchaseIssue)

            try context.session.resolveIssueForTransaction(
                identifier: interrupted.identifier
            )

            try await context.waitForEntitlements([.tier1])
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
            decidePolicy: { _ in
                await rejectedHandlerCalls.send()
                return .finish
            },
            didFail: { failure in
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

            _ = try await session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await updateFailures.wait(for: 1)

            #expect(await rejectedHandlerCalls.value() == 0)
            #expect(observedStore.store.activeEntitlements == [])
        }

        let unfinishedFailures = TestSignal()
        try await withObservedStore(
            decidePolicy: { _ in
                await rejectedHandlerCalls.send()
                return .finish
            },
            didFail: { failure in
                if case .unfinished = failure.source {
                    await unfinishedFailures.send()
                }
            }
        ) { _ in
            try await unfinishedFailures.wait(for: 1)
            #expect(await rejectedHandlerCalls.value() == 0)
        }

        try await session.setSimulatedError(nil, forAPI: .verification)
    }

    @Test
    func upgradeFromTier1ToTier2PublishesOnlyTier2() async throws {
        try await withTestContext { context in
            _ = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await context.waitForEntitlements([.tier1])

            _ = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier2_Monthly.rawValue
            )

            try await context.waitForEntitlements([.tier2])
        }
    }

    @Test
    func downgradeFromTier2ToTier1ChangesAtRenewal() async throws {
        try await withTestContext { context in
            _ = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier2_Monthly.rawValue
            )
            try await context.waitForEntitlements([.tier2])

            _ = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )

            let preRenewalEntitlements = try await context.store.refreshEntitlements()
            #expect(
                preRenewalEntitlements.transactions.map(\.productID)
                    == [Plans.ProductID.tier2_Monthly.rawValue]
            )
            #expect(context.store.activeEntitlements == [.tier2])
            try context.session.forceRenewalOfSubscription(
                productIdentifier: Plans.ProductID.tier2_Monthly.rawValue
            )
            try await context.waitForEntitlements([.tier1])
        }
    }

    @Test
    func cancellationKeepsTier1UntilExpirationThenRemovesIt() async throws {
        try await withTestContext { context in
            let transaction = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await context.waitForEntitlements([.tier1])

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
                    == [Plans.ProductID.tier1_Monthly.rawValue]
            )
            #expect(context.store.activeEntitlements == [.tier1])

            try context.session.expireSubscription(
                productIdentifier: Plans.ProductID.tier1_Monthly.rawValue
            )

            if #available(iOS 27.0,
            tvOS 27.0,
            watchOS 27.0,
            visionOS 27.0,
            *) {
                let expiredEntitlements =
                    try await context.store.restorePurchases()
                #expect(expiredEntitlements.transactions.isEmpty)
                #expect(context.store.activeEntitlements == [])
            } else {
                try await context.waitForEntitlements([])
            }
        }
    }

    @Test
    func renewalPublishesTheNewTransactionLineage() async throws {
        try await withTestContext { context in
            let initial = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await context.waitForEntitlements([.tier1])

            try context.session.forceRenewalOfSubscription(
                productIdentifier: Plans.ProductID.tier1_Monthly.rawValue
            )

            let renewal = try await context.waitForTransaction(
                productID: Plans.ProductID.tier1_Monthly.rawValue,
                excluding: initial.id
            )
            #expect(renewal.originalID == initial.originalID)
            #expect(renewal.reason == .renewal)
            #expect(context.store.activeEntitlements == [.tier1])
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
            decidePolicy: { transaction in
                if transaction.reason == .renewal {
                    await renewalHandlerStarted.send()
                    try await renewalHandlerRelease.wait(for: 1)
                }
                return .finish
            },
            didFail: { failure in
                Issue.record("Unexpected renewal failure: \(failure)")
            }
        )

        do {
            try await observedStore.waitForEntitlements([])
            let initial = try await session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await observedStore.waitForEntitlements([.tier1])

            try session.forceRenewalOfSubscription(
                productIdentifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await renewalHandlerStarted.wait(for: 1)

            #expect(
                observedStore.store.entitlements?.transactions.first?.id
                    == initial.id
            )
            await renewalHandlerRelease.send()
            let renewal = try await observedStore.waitForTransaction(
                productID: Plans.ProductID.tier1_Monthly.rawValue,
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
            decidePolicy: { _ in
                await replayedHandlerCalls.send()
                return .finish
            },
            didFail: { failure in
                Issue.record("Unexpected post-renewal failure: \(failure)")
            }
        ) { observedStore in
            try await observedStore.waitForEntitlements([.tier1])
            #expect(await replayedHandlerCalls.value() == 0)
        }
    }

    @Test
    func refundRemovesTheEntitlement() async throws {
        try await withTestContext { context in
            let transaction = try await context.session.buyProduct(
                identifier: Plans.ProductID.tier1_Monthly.rawValue
            )
            try await context.waitForEntitlements([.tier1])

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
        try await withTestContext(preexistingSubscription: .tier1_Yearly) { context in
            let entitlements = try await context.store.restorePurchases()

            #expect(
                entitlements.transactions.map(\.productID)
                    == [Plans.ProductID.tier1_Yearly.rawValue]
            )
            #expect(context.store.activeEntitlements == [.tier1])
        }
    }

    @Test
    func restorePropagatesAppStoreSyncFailure() async throws {
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

            var capturedRestoreError: (any Error)?
            do {
                _ = try await context.store.restorePurchases()
            } catch {
                capturedRestoreError = error
            }
            let restoreError = try #require(
                capturedRestoreError,
                "Expected restorePurchases() to fail."
            )
            if #unavailable(iOS 27.0,
            tvOS 27.0,
            watchOS 27.0,
            visionOS 27.0) {
                guard case StoreKitError.networkError(let error) = restoreError else {
                    Issue.record("Unexpected restore error: \(restoreError)")
                    return
                }
                #expect(error.code == .notConnectedToInternet)
            } else {
                guard case StoreKitError.systemError = restoreError else {
                    Issue.record("Unexpected restore error: \(restoreError)")
                    return
                }
            }
            #expect(context.store.activeEntitlements == [])
        }
    }

    @Test
    func askToBuyResolutionMatchesTheStoreKitTestRuntime() async throws {
        try await withTestContext { context in
            context.session.askToBuyEnabled = true
            let product = try await context.product(.tier1_Monthly)
            let result = try await purchase(product)

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
            if #available(iOS 27.0,
            tvOS 27.0,
            watchOS 27.0,
            visionOS 27.0,
            *) {
                try context.session.approveAskToBuyTransaction(
                    identifier: pending.identifier
                )
                try await context.waitForEntitlements([.tier1])
            } else {
                try context.session.declineAskToBuyTransaction(
                    identifier: pending.identifier
                )

                let entitlements =
                    try await context.store.restorePurchases()
                #expect(entitlements.transactions.isEmpty)
                #expect(context.store.activeEntitlements == [])
                #expect(
                    context.session.allTransactions().allSatisfy {
                        !$0.pendingAskToBuyConfirmation
                    }
                )
            }
        }
    }

    private func purchase(
        _ product: Product,
        options: Set<Product.PurchaseOption> = []
    ) async throws -> Product.PurchaseResult {
        #if os(visionOS)
            let scene = try #require(
                UIApplication.shared.connectedScenes.first {
                    $0.activationState == .foregroundActive
                },
                "The visionOS test host does not have a foreground scene."
            )
            return try await product.purchase(confirmIn: scene, options: options)
        #else
            return try await product.purchase(options: options)
        #endif
    }

    private func withTestContext(
        preexistingSubscription: Plans.ProductID? = nil,
        preexistingPurchaseOptions: Set<Product.PurchaseOption> = [],
        expectedEntitlements: Set<SubscriptionEntitlement>? = nil,
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

    var store: TransactionStore<SubscriptionEntitlement> {
        observedStore.store
    }

    init(
        preexistingSubscription: Plans.ProductID? = nil,
        preexistingPurchaseOptions: Set<Product.PurchaseOption> = [],
        expectedEntitlements: Set<SubscriptionEntitlement>? = nil
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
            decidePolicy: { _ in .automatic },
            didFail: { error in
                Issue.record("Background transaction failure: \(error)")
            }
        )
        self.observedStore = observedStore
        let expected =
            expectedEntitlements
            ?? preexistingSubscription.map {
                switch $0 {
                case .tier1_Monthly, .tier1_Yearly:
                    [.tier1]
                case .tier2_Monthly, .tier2_Yearly:
                    [.tier2]
                }
            }
            ?? []
        try await observedStore.waitForEntitlements(expected)
        guard case .ready = store.entitlementStatus else {
            Issue.record("The store did not reach ready entitlement state.")
            return
        }
    }

    func product(_ productID: Plans.ProductID) async throws -> Product {
        try #require(
            try await Product.products(for: [productID.rawValue]).first
        )
    }

    func waitForEntitlements(
        _ expected: Set<SubscriptionEntitlement>
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
    let store: TransactionStore<SubscriptionEntitlement>
    let observation: TransactionStoreObservation

    init(
        decidePolicy:
            @escaping @Sendable (StoreTransactionSnapshot) async throws
            -> StoreTransactionHandlingPolicy,
        didFail:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        let delegate = ClosureTransactionStoreDelegate(
            decidePolicy: decidePolicy,
            didFail: didFail
        )
        let store = TransactionStore(
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate
        )
        self.store = store
        self.observation = TransactionStoreObservation(store: store)
    }

    func waitForEntitlements(
        _ expected: Set<SubscriptionEntitlement>
    ) async throws {
        while true {
            let generation = observation.generation
            guard store.activeEntitlements != expected else { return }
            try await observation.waitForChange(after: generation)
        }
    }

    func waitForStartupFailure() async throws {
        while true {
            let generation = observation.generation
            guard case .failed = store.entitlementStatus else {
                try await observation.waitForChange(after: generation)
                continue
            }
            return
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

private final class ClosureTransactionStoreDelegate: TransactionStoreDelegate {
    private let policy:
        @Sendable (StoreTransactionSnapshot) async throws
            -> StoreTransactionHandlingPolicy
    private let failure: @Sendable (StoreTransactionBackgroundFailure) async -> Void

    init(
        decidePolicy:
            @escaping @Sendable (StoreTransactionSnapshot) async throws
            -> StoreTransactionHandlingPolicy,
        didFail:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        self.policy = decidePolicy
        self.failure = didFail
    }

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        try await policy(transaction)
    }

    func didFail(
        with failure: StoreTransactionBackgroundFailure
    ) async {
        await self.failure(failure)
    }
}

@MainActor
private func withObservedStore(
    decidePolicy:
        @escaping @Sendable (StoreTransactionSnapshot) async throws
        -> StoreTransactionHandlingPolicy,
    didFail:
        @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void,
    _ body: (ObservedStore) async throws -> Void
) async throws {
    let observedStore = ObservedStore(
        decidePolicy: decidePolicy,
        didFail: didFail
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
    private weak var store: TransactionStore<SubscriptionEntitlement>?
    private let changes: AsyncStream<UInt64>
    private let continuation: AsyncStream<UInt64>.Continuation
    private(set) var generation: UInt64 = 0

    init(store: TransactionStore<SubscriptionEntitlement>) {
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
            _ = store.activeEntitlements
            _ = store.entitlementStatus
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
                for: [Plans.ProductID.tier1_Monthly.rawValue]
            ).first,
            "The StoreKit test configuration is not active."
        )
        isAvailable = true
    }
}

private final class BundleToken {}
