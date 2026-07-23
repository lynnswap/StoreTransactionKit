import Foundation
import StoreTransactionKit
import StoreTransactionKitTesting
import StoreKit
import Synchronization
import Testing

@Suite("TransactionStoreTestHarness", .timeLimit(.minutes(1)))
struct TransactionStoreTestHarnessTests {
    @MainActor
    @Test("construction publishes a ready empty entitlement set")
    func readyEmptyConstruction() async throws {
        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog
        ) { harness in
            guard case .ready = harness.store.entitlementStatus else {
                Issue.record("The synthetic store did not become ready.")
                return
            }
            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])
            #expect(!harness.store.isEntitled(to: .tier1))
        }
    }

    @MainActor
    @Test("purchase returns after policy, acknowledgement, and publication")
    func purchaseCompletion() async throws {
        let delegate = ActorRecordingDelegate()

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: delegate
        ) { harness in
            let snapshot = try await harness.purchase(
                .tier1_Monthly,
                in: HarnessPlans.self
            )

            #expect(snapshot.id == 1)
            #expect(snapshot.originalID == 1)
            #expect(snapshot.productID == HarnessPlans.ProductID.tier1_Monthly.rawValue)
            #expect(snapshot.subscriptionGroupID == HarnessPlans.id.rawValue)
            #expect(snapshot.productType == .autoRenewable)
            #expect(snapshot.jwsRepresentation == "StoreTransactionKitTesting.synthetic.1")
            #expect(harness.store.entitlements?.transactions == [snapshot])
            #expect(harness.store.activeEntitlements == [.tier1])
            #expect(harness.store.isEntitled(to: .tier1))
            #expect(await delegate.snapshot() == .init(decisions: 1, failures: 0))
        }
    }

    @MainActor
    @Test("a later product replaces the active synthetic subscription")
    func purchaseReplacement() async throws {
        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog
        ) { harness in
            let first = try await harness.purchase(
                .tier1_Yearly,
                in: HarnessPlans.self
            )
            let second = try await harness.purchase(
                .tier2_Monthly,
                in: HarnessPlans.self
            )

            #expect(first.id == 1)
            #expect(second.id == 2)
            #expect(harness.store.entitlements?.transactions == [second])
            #expect(harness.store.activeEntitlements == [.tier2])
            #expect(!harness.store.isEntitled(to: .tier1))
            #expect(harness.store.isEntitled(to: .tier2))

            let refreshed = try await harness.store.refreshEntitlements()
            #expect(refreshed.transactions == [second])
        }
    }

    @MainActor
    @Test("default unrecognized policy publishes raw ready state without entitlement")
    func defaultUnrecognizedPolicy() async throws {
        let generalDelegate = ActorRecordingDelegate()

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: generalDelegate
        ) { harness in
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )

            #expect(
                try await harness.deliver(transaction)
                    == .leftUnfinished(transaction)
            )
            #expect(harness.store.entitlements?.transactions == [transaction])
            #expect(harness.store.activeEntitlements == [])
            #expect(
                await generalDelegate.snapshot()
                    == .init(decisions: 0, failures: 0)
            )
        }
    }

    @MainActor
    @Test("explicit leave policy is reused for an exact revision")
    func explicitLeavePolicyReplay() async throws {
        let delegate = HarnessUnrecognizedDelegate(policy: .leaveUnfinished)

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: delegate
        ) { harness in
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )

            #expect(
                try await harness.deliver(transaction)
                    == .leftUnfinished(transaction)
            )
            #expect(
                try await harness.deliver(transaction)
                    == .leftUnfinished(transaction)
            )
            #expect(await delegate.decisionCount() == 1)
            #expect(harness.store.entitlements?.transactions == [transaction])
            #expect(harness.store.activeEntitlements == [])
        }
    }

    @MainActor
    @Test("finish policy completes without a typed entitlement")
    func unrecognizedFinishPolicy() async throws {
        let delegate = HarnessUnrecognizedDelegate(policy: .finish)

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: delegate
        ) { harness in
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )

            #expect(
                try await harness.deliver(transaction)
                    == .completed(transaction)
            )
            #expect(await delegate.decisionCount() == 1)
            #expect(harness.store.entitlements?.transactions == [transaction])
            #expect(harness.store.activeEntitlements == [])
        }
    }

    @MainActor
    @Test("treat-as policy persists through explicit refresh")
    func unrecognizedTreatAsPolicy() async throws {
        let delegate = HarnessUnrecognizedDelegate(policy: .treatAs(.tier1))

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: delegate
        ) { harness in
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )

            #expect(
                try await harness.deliver(transaction)
                    == .completed(transaction)
            )
            #expect(harness.store.activeEntitlements == [.tier1])

            let refreshed = try await harness.store.refreshEntitlements()

            #expect(refreshed.transactions == [transaction])
            #expect(harness.store.activeEntitlements == [.tier1])
            #expect(await delegate.decisionCount() == 1)
        }
    }

    @MainActor
    @Test("a thrown decision can retry the same registered revision")
    func unrecognizedDecisionRetry() async throws {
        let delegate = HarnessUnrecognizedDelegate { _, attempt in
            if attempt == 1 {
                throw HarnessTestError.decision
            }
            return .treatAs(.tier1)
        }

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: delegate
        ) { harness in
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )

            await #expect(throws: HarnessTestError.decision) {
                _ = try await harness.deliver(transaction)
            }
            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])
            #expect(await delegate.decisionCount() == 1)

            #expect(
                try await harness.deliver(transaction)
                    == .completed(transaction)
            )
            #expect(harness.store.entitlements?.transactions == [transaction])
            #expect(harness.store.activeEntitlements == [.tier1])
            #expect(await delegate.decisionCount() == 2)
        }
    }

    @MainActor
    @Test("concurrent delivery of one revision joins one policy decision")
    func concurrentUnrecognizedDelivery() async throws {
        let decisionStarted = HarnessTestSignal()
        let decisionGate = HarnessTestGate()
        let secondStarted = HarnessTestSignal()
        let delegate = HarnessUnrecognizedDelegate { _, _ in
            decisionStarted.send()
            try await decisionGate.wait()
            return .treatAs(.tier1)
        }

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: delegate
        ) { harness in
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )
            let first = Task { @MainActor in
                try await harness.deliver(transaction)
            }
            await decisionStarted.wait()

            let second = Task { @MainActor in
                secondStarted.send()
                return try await harness.deliver(transaction)
            }
            await secondStarted.wait()
            #expect(await delegate.decisionCount() == 1)

            await decisionGate.open()
            #expect(try await first.value == .completed(transaction))
            #expect(try await second.value == .completed(transaction))
            #expect(await delegate.decisionCount() == 1)
            #expect(harness.store.activeEntitlements == [.tier1])
        }
    }

    @MainActor
    @Test("unrecognized validation completes before production admission")
    func unrecognizedValidationPrecedesAdmission() async throws {
        let generalDelegate = ActorRecordingDelegate()
        let unrecognizedDelegate = HarnessUnrecognizedDelegate(policy: .finish)
        var foreignTransaction: StoreTransactionSnapshot?

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        ) { harness in
            await expectHarnessError(
                .subscriptionGroupMismatch(
                    expected: HarnessPlans.id,
                    actual: DifferentIDPlans.id
                )
            ) {
                _ = try harness.makeUnrecognizedSubscription(
                    productID: "testing.subscription.legacy",
                    in: DifferentIDPlans.self
                )
            }
            await expectHarnessError(
                .subscriptionGroupTypeMismatch(
                    subscriptionGroupID: HarnessPlans.id
                )
            ) {
                _ = try harness.makeUnrecognizedSubscription(
                    productID: "testing.subscription.legacy",
                    in: SubstitutedPlans.self
                )
            }
            await expectHarnessError(
                .declaredProduct(
                    productID:
                        HarnessPlans.ProductID.tier1_Monthly.rawValue,
                    subscriptionGroupID: HarnessPlans.id
                )
            ) {
                _ = try harness.makeUnrecognizedSubscription(
                    productID:
                        HarnessPlans.ProductID.tier1_Monthly.rawValue,
                    in: HarnessPlans.self
                )
            }

            try await withTransactionStoreTestHarness(
                subscriptionCatalog: harnessSubscriptionCatalog
            ) { foreignHarness in
                foreignTransaction =
                    try foreignHarness.makeUnrecognizedSubscription(
                        productID: "testing.subscription.foreign",
                        in: HarnessPlans.self
                    )
            }
            let foreignTransaction = try #require(foreignTransaction)
            await expectHarnessError(
                .unregisteredTransaction(
                    transactionID: foreignTransaction.id
                )
            ) {
                _ = try await harness.deliver(foreignTransaction)
            }

            #expect(
                await generalDelegate.snapshot()
                    == .init(decisions: 0, failures: 0)
            )
            #expect(await unrecognizedDelegate.decisionCount() == 0)
            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])

            let firstRegistered =
                try harness.makeUnrecognizedSubscription(
                    productID: "testing.subscription.legacy",
                    in: HarnessPlans.self
                )
            #expect(firstRegistered.id == 1)
            #expect(
                try await harness.deliver(firstRegistered)
                    == .completed(firstRegistered)
            )
        }
    }

    @MainActor
    @Test("group and product validation completes before production admission")
    func validationPrecedesAdmission() async throws {
        let delegate = ActorRecordingDelegate()

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: delegate
        ) { harness in
            await expectHarnessError(
                .subscriptionGroupMismatch(
                    expected: HarnessPlans.id,
                    actual: DifferentIDPlans.id
                )
            ) {
                try await harness.purchase(
                    .monthly,
                    in: DifferentIDPlans.self
                )
            }
            await expectHarnessError(
                .subscriptionGroupTypeMismatch(
                    subscriptionGroupID: HarnessPlans.id
                )
            ) {
                try await harness.purchase(
                    .monthly,
                    in: SubstitutedPlans.self
                )
            }
            await expectHarnessError(
                .undeclaredProduct(
                    productID: HarnessPlans.ProductID.undeclared.rawValue,
                    subscriptionGroupID: HarnessPlans.id
                )
            ) {
                try await harness.purchase(
                    .undeclared,
                    in: HarnessPlans.self
                )
            }

            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])
            #expect(await delegate.snapshot() == .init(decisions: 0, failures: 0))

            let firstAdmitted = try await harness.purchase(
                .tier1_Monthly,
                in: HarnessPlans.self
            )
            #expect(firstAdmitted.id == 1)
        }
    }

    @MainActor
    @Test("cancellation already set before admission starts no transaction work")
    func preAdmissionCancellation() async throws {
        let delegate = ActorRecordingDelegate()
        let clock = TransactionStoreTestClock()

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: delegate
        ) { harness in
            let purchase = Task { @MainActor in
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch is CancellationError {
                    // Preserve the task's cancellation flag before entering purchase.
                }
                return try await harness.purchase(
                    .tier1_Monthly,
                    in: HarnessPlans.self
                )
            }
            try await clock.waitUntilPendingSleepCount(reaches: 1)

            purchase.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await purchase.value
            }

            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])
            #expect(await delegate.snapshot() == .init(decisions: 0, failures: 0))

            let firstAdmitted = try await harness.purchase(
                .tier1_Monthly,
                in: HarnessPlans.self
            )
            #expect(firstAdmitted.id == 1)
        }
    }

    @MainActor
    @Test("decision failure is returned directly without acknowledging the purchase")
    func decisionFailure() async throws {
        let delegate = ThrowingDelegate()

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: delegate
        ) { harness in
            await #expect(throws: HarnessTestError.decision) {
                try await harness.purchase(
                    .tier1_Monthly,
                    in: HarnessPlans.self
                )
            }

            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])
            #expect(await delegate.snapshot() == .init(decisions: 1, failures: 0))
        }
    }

    @MainActor
    @Test("unsupported live operations fail before source or delegate work")
    func unsupportedOperations() async throws {
        let delegate = ActorRecordingDelegate()

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: delegate
        ) { harness in
            await expectHarnessError(
                .operationUnavailable(operation: .processPurchase)
            ) {
                _ = try await harness.store.process(.pending)
            }
            await expectHarnessError(.operationUnavailable(operation: .history)) {
                _ = try await harness.store.history(for: "test.product")
            }
            await expectHarnessError(
                .operationUnavailable(operation: .restorePurchases)
            ) {
                _ = try await harness.store.restorePurchases()
            }

            #expect(harness.store.entitlements?.transactions.isEmpty == true)
            #expect(harness.store.activeEntitlements == [])
            #expect(await delegate.snapshot() == .init(decisions: 0, failures: 0))
        }
    }

    @MainActor
    @Test("multiple synthetic stores coexist without live StoreKit authority")
    func multipleSyntheticStores() async throws {
        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog
        ) { first in
            try await withTransactionStoreTestHarness(
                subscriptionCatalog: harnessSubscriptionCatalog
            ) { second in
                _ = try await first.purchase(
                    .tier1_Monthly,
                    in: HarnessPlans.self
                )
                _ = try await second.purchase(
                    .tier2_Monthly,
                    in: HarnessPlans.self
                )

                #expect(first.store.activeEntitlements == [.tier1])
                #expect(second.store.activeEntitlements == [.tier2])
            }
        }
    }

    @MainActor
    @Test("a class delegate can delay policy with the deterministic clock")
    func classDelegateClockIntegration() async throws {
        let clock = TransactionStoreTestClock()
        let delegate = DelayedClassDelegate(clock: clock)

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog,
            delegate: delegate
        ) { harness in
            let purchase = Task { @MainActor in
                try await harness.purchase(
                    .tier2_Monthly,
                    in: HarnessPlans.self
                )
            }

            try await clock.waitUntilPendingSleepCount(reaches: 1)
            #expect(harness.store.activeEntitlements == [])
            #expect(delegate.decisionCount == 1)

            clock.advance(by: .seconds(30))
            let snapshot = try await purchase.value

            #expect(harness.store.entitlements?.transactions == [snapshot])
            #expect(harness.store.activeEntitlements == [.tier2])
        }
    }

    @MainActor
    @Test("scoped cleanup closes a retained harness after success")
    func scopedSuccessCleanup() async throws {
        var retained: TransactionStoreTestHarness<HarnessEntitlement>?

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog
        ) { harness in
            retained = harness
        }

        try await expectClosed(try #require(retained))
    }

    @MainActor
    @Test("scoped cleanup closes a store with a left-unfinished revision")
    func scopedUnfinishedCleanup() async throws {
        var retained: TransactionStoreTestHarness<HarnessEntitlement>?

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog
        ) { harness in
            retained = harness
            let transaction = try harness.makeUnrecognizedSubscription(
                productID: "testing.subscription.legacy",
                in: HarnessPlans.self
            )
            #expect(
                try await harness.deliver(transaction)
                    == .leftUnfinished(transaction)
            )
        }

        try await expectClosed(try #require(retained))
    }

    @MainActor
    @Test("scoped cleanup closes a retained harness after operation failure")
    func scopedFailureCleanup() async throws {
        var retained: TransactionStoreTestHarness<HarnessEntitlement>?

        await #expect(throws: HarnessTestError.operation) {
            try await withTransactionStoreTestHarness(
                subscriptionCatalog: harnessSubscriptionCatalog
            ) { harness -> Void in
                retained = harness
                throw HarnessTestError.operation
            }
        }

        try await expectClosed(try #require(retained))
    }

    @MainActor
    @Test("scoped cleanup drains after operation cancellation")
    func scopedCancellationCleanup() async throws {
        let clock = TransactionStoreTestClock()
        var retained: TransactionStoreTestHarness<HarnessEntitlement>?
        let scoped = Task { @MainActor in
            try await withTransactionStoreTestHarness(
                subscriptionCatalog: harnessSubscriptionCatalog
            ) { harness in
                retained = harness
                try await clock.sleep(for: .seconds(1))
            }
        }
        try await clock.waitUntilPendingSleepCount(reaches: 1)

        scoped.cancel()
        await #expect(throws: CancellationError.self) {
            try await scoped.value
        }

        try await expectClosed(try #require(retained))
    }

    @MainActor
    @Test("scoped cleanup is idempotent when the operation closes the store")
    func operationClosesStore() async throws {
        var retained: TransactionStoreTestHarness<HarnessEntitlement>?

        try await withTransactionStoreTestHarness(
            subscriptionCatalog: harnessSubscriptionCatalog
        ) { harness in
            retained = harness
            try await harness.store.close()
        }

        try await expectClosed(try #require(retained))
    }
}

private enum HarnessEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

private enum HarnessPlans: AutoRenewableSubscriptionGroup<HarnessEntitlement> {
    static let id = SubscriptionGroupID(
        rawValue: "testing.subscription.group"
    )

    enum ProductID: String, Hashable, Sendable {
        case tier1_Monthly = "testing.subscription.tier1.monthly"
        case tier1_Yearly = "testing.subscription.tier1.yearly"
        case tier2_Monthly = "testing.subscription.tier2.monthly"
        case undeclared = "testing.subscription.undeclared"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.tier1_Monthly, entitlement: .tier1)
        StoreSubscription(.tier1_Yearly, entitlement: .tier1)
        StoreSubscription(.tier2_Monthly, entitlement: .tier2)
    }
}

private enum DifferentIDPlans:
    AutoRenewableSubscriptionGroup<HarnessEntitlement>
{
    static let id = SubscriptionGroupID(
        rawValue: "testing.subscription.other-group"
    )

    enum ProductID: String, Hashable, Sendable {
        case monthly = "testing.subscription.tier1.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.monthly, entitlement: .tier1)
    }
}

private enum SubstitutedPlans:
    AutoRenewableSubscriptionGroup<HarnessEntitlement>
{
    static let id = HarnessPlans.id

    enum ProductID: String, Hashable, Sendable {
        case monthly = "testing.subscription.tier1.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.monthly, entitlement: .tier1)
    }
}

private let harnessSubscriptionCatalog =
    AutoRenewableSubscriptionCatalog<HarnessEntitlement>(HarnessPlans.self)

private enum HarnessTestError: Error, Sendable {
    case decision
    case operation
}

private struct DelegateSnapshot: Equatable, Sendable {
    let decisions: Int
    let failures: Int
}

private actor ActorRecordingDelegate: TransactionStoreDelegate {
    private var decisions = 0
    private var failures = 0

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        decisions += 1
        return .finish
    }

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        failures += 1
    }

    func snapshot() -> DelegateSnapshot {
        DelegateSnapshot(decisions: decisions, failures: failures)
    }
}

private actor ThrowingDelegate: TransactionStoreDelegate {
    private var decisions = 0
    private var failures = 0

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        decisions += 1
        throw HarnessTestError.decision
    }

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        failures += 1
    }

    func snapshot() -> DelegateSnapshot {
        DelegateSnapshot(decisions: decisions, failures: failures)
    }
}

private typealias HarnessUnrecognizedPolicy =
    UnrecognizedSubscriptionPolicy<HarnessEntitlement>

private actor HarnessUnrecognizedDelegate:
    UnrecognizedSubscriptionDelegate
{
    typealias Entitlement = HarnessEntitlement

    private let decide:
        @Sendable (StoreTransactionSnapshot, Int) async throws
            -> HarnessUnrecognizedPolicy
    private var transactions: [StoreTransactionSnapshot] = []

    init(policy: HarnessUnrecognizedPolicy) {
        decide = { _, _ in policy }
    }

    init(
        decide:
            @escaping @Sendable (StoreTransactionSnapshot, Int) async throws
            -> HarnessUnrecognizedPolicy
    ) {
        self.decide = decide
    }

    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> HarnessUnrecognizedPolicy {
        transactions.append(transaction)
        return try await decide(transaction, transactions.count)
    }

    func decisionCount() -> Int {
        transactions.count
    }
}

private final class HarnessTestSignal: Sendable {
    private struct State {
        var isSignaled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func send() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard !state.isSignaled else { return nil }
            state.isSignaled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isSignaled {
                    return true
                } else {
                    precondition(state.waiter == nil)
                    state.waiter = continuation
                    return false
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor HarnessTestGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        guard !isOpen else { return }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func open() {
        isOpen = true
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }
}

private final class DelayedClassDelegate: TransactionStoreDelegate {
    private let clock: any Clock<Duration>
    private let decisions = Mutex(0)

    var decisionCount: Int {
        decisions.withLock { $0 }
    }

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        decisions.withLock { $0 += 1 }
        try await clock.sleep(for: .seconds(30))
        return .finish
    }
}

@MainActor
private func expectHarnessError(
    _ expected: TransactionStoreTestHarnessError,
    performing operation: @MainActor () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected test harness error: \(expected)")
    } catch let error as TransactionStoreTestHarnessError {
        #expect(error == expected)
        #expect(error.errorDescription != nil)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@MainActor
private func expectClosed(
    _ harness: TransactionStoreTestHarness<HarnessEntitlement>
) async throws {
    do {
        _ = try await harness.store.history(for: "test.product")
        Issue.record("The retained synthetic store was not closed.")
    } catch StoreTransactionError.closed {
        return
    }
}
