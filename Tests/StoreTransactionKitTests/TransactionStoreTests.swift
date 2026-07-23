import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("TransactionStore", .timeLimit(.minutes(1)))
struct TransactionStoreTests {
    @MainActor
    @Test("override mode publishes an authoritative typed set without raw state")
    func overrideState() async throws {
        let store = TransactionStore(
            subscriptionCatalog: testSubscriptionCatalog,
            overridingEntitlements: [
                TestEntitlement.tier1,
                .tier1,
            ]
        )

        guard case .overridden = store.entitlementStatus else {
            Issue.record("Expected override availability.")
            return
        }
        #expect(store.entitlements == nil)
        #expect(store.activeEntitlements == [.tier1])
        #expect(store.isEntitled(to: .tier1))
        #expect(!store.isEntitled(to: .tier2))

        do {
            _ = try await store.refreshEntitlements()
            Issue.record("Override mode unexpectedly refreshed StoreKit.")
        } catch StoreTransactionError.operationUnavailableInOverride(
            operation: .refreshEntitlements
        ) {}

        try await store.close()
        try await store.close()
    }

    @MainActor
    @Test("initial publication commits raw and typed entitlement state together")
    func initialPublication() async throws {
        let snapshot = makeSubscriptionSnapshot(
            id: 1,
            productID: .tier1Monthly
        )
        let fixture = TestSourceFixture(currentEntitlements: { [snapshot] })
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )

        try await store.waitForInitialReadiness()

        guard case .ready = store.entitlementStatus else {
            Issue.record("Expected ready availability.")
            try await store.close()
            return
        }
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("a successful direct delivery decides, finishes, refreshes, and publishes")
    func directDelivery() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let finishes = TestSignal()
        let snapshot = makeSubscriptionSnapshot(
            id: 2,
            productID: .tier1Yearly
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        let outcome = try await store.process(
            .verified(
                makeEnvelope(snapshot: snapshot, revision: "direct-2") {
                    await finishes.send()
                }
            )
        )

        #expect(outcome == .completed(snapshot))
        #expect(await finishes.value() == 1)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("transient refresh failure preserves a prior ready snapshot")
    func transientFailurePreservesReadyState() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let snapshot = makeSubscriptionSnapshot(
            id: 3,
            productID: .tier2Monthly
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )

        try await query.waitForRequest(1)
        await query.succeed([snapshot])
        try await store.waitForInitialReadiness()

        let refresh = Task { @MainActor in
            try await store.refreshEntitlements()
        }
        try await query.waitForRequest(2)
        await query.fail(TestFailure())
        await #expect(throws: TestFailure.self) {
            _ = try await refresh.value
        }

        guard case .ready = store.entitlementStatus else {
            Issue.record("A transient failure discarded ready state.")
            try await store.close()
            return
        }
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier2])
        try await store.close()
    }

    @MainActor
    @Test("catalog contradiction fails closed and clears both projections")
    func catalogFailureClearsState() async throws {
        let current = EntitlementValueSource([
            makeSubscriptionSnapshot(id: 4, productID: .tier1Monthly)
        ])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await store.waitForInitialReadiness()

        let contradictory = makeSnapshot(
            id: 5,
            productID: TestPlans.ProductID.tier1Monthly.rawValue,
            productType: .nonConsumable,
            subscriptionGroupID: TestPlans.id.rawValue
        )
        await current.replace(with: [contradictory])

        await #expect(throws: AutoRenewableSubscriptionCatalogError.self) {
            _ = try await store.refreshEntitlements()
        }
        guard case .failed(let error) = store.entitlementStatus else {
            Issue.record("Expected catalog failure availability.")
            try await store.close()
            return
        }
        #expect(error is AutoRenewableSubscriptionCatalogError)
        #expect(store.entitlements == nil)
        #expect(store.activeEntitlements == nil)
        try await store.close()
    }

    @MainActor
    @Test("post-finish failure retries only the causal refresh on redelivery")
    func postFinishRedeliveryRetriesRefreshOnly() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let delegate = CountingDelegate(policy: .automatic)
        let finishes = TestSignal()
        let snapshot = makeSubscriptionSnapshot(
            id: 6,
            productID: .tier1Monthly,
            revision: "post-finish"
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "post-finish") {
                await finishes.send()
            }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )

        try await query.waitForRequest(1)
        await query.succeed([])
        try await store.waitForInitialReadiness()

        let first = Task { @MainActor in
            try await store.process(delivery)
        }
        try await query.waitForRequest(2)
        await query.fail(TestFailure())
        do {
            _ = try await first.value
            Issue.record("Expected post-finish refresh failure.")
        } catch StoreTransactionError.entitlementRefreshFailed(
            after: .finishedTransaction(let completed),
            underlyingError: let error
        ) {
            #expect(completed == snapshot)
            #expect(error is TestFailure)
        }

        let second = Task { @MainActor in
            try await store.process(delivery)
        }
        try await query.waitForRequest(3)
        await query.succeed([snapshot])
        #expect(try await second.value == .completed(snapshot))

        #expect(await delegate.decisionCount() == 1)
        #expect(await finishes.value() == 1)
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("a satisfied exact revision suppresses policy, finish, and refresh")
    func satisfiedDuplicateIsFullySuppressed() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let delegate = CountingDelegate(policy: .automatic)
        let finishes = TestSignal()
        let snapshot = makeSubscriptionSnapshot(
            id: 7,
            productID: .tier1Monthly,
            revision: "satisfied"
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "satisfied") {
                await finishes.send()
            }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        _ = try await store.process(delivery)
        let queryCount = await fixture.entitlementQueryCount.value()
        _ = try await store.process(delivery)

        #expect(await delegate.decisionCount() == 1)
        #expect(await finishes.value() == 1)
        #expect(await fixture.entitlementQueryCount.value() == queryCount)
        try await store.close()
    }

    @MainActor
    @Test("a duplicate admitted during causal refresh joins the exact revision")
    func duplicateDuringRefreshJoins() async throws {
        let query = ControlledEntitlementQuery()
        let delegate = CountingDelegate(policy: .automatic)
        let finishes = TestSignal()
        let secondAdmitted = TestSignal()
        let snapshot = makeSubscriptionSnapshot(
            id: 70,
            productID: .tier2Monthly,
            revision: "joined"
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "joined") {
                await finishes.send()
            }
        )
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await query.waitForRequest(1)
        await query.succeed([])
        try await store.waitForInitialReadiness()

        let first = Task { @MainActor in try await store.process(delivery) }
        try await query.waitForRequest(2)
        let second = Task { @MainActor in
            try await store.process(delivery) {
                await secondAdmitted.send()
            }
        }
        try await secondAdmitted.wait(for: 1)
        await query.succeed([snapshot])

        #expect(try await first.value == .completed(snapshot))
        #expect(try await second.value == .completed(snapshot))
        #expect(await delegate.decisionCount() == 1)
        #expect(await finishes.value() == 1)
        #expect(await fixture.entitlementQueryCount.value() == 2)
        try await store.close()
    }

    @MainActor
    @Test("a thrown decision is retryable and never finishes its failed attempt")
    func decisionFailureRetriesPolicy() async throws {
        let current = EntitlementValueSource([])
        let delegate = RetryDecisionDelegate()
        let finishes = TestSignal()
        let snapshot = makeSubscriptionSnapshot(
            id: 71,
            productID: .tier1Monthly,
            revision: "decision-retry"
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "decision-retry") {
                await finishes.send()
            }
        )
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        await #expect(throws: TestFailure.self) {
            _ = try await store.process(delivery)
        }
        #expect(await finishes.value() == 0)
        #expect(await fixture.entitlementQueryCount.value() == 1)

        await current.replace(with: [snapshot])
        #expect(try await store.process(delivery) == .completed(snapshot))
        #expect(await delegate.decisionCount() == 2)
        #expect(await finishes.value() == 1)
        try await store.close()
    }

    @MainActor
    @Test("finish policy permits an app-owned unmanaged transaction")
    func finishPolicyHandlesUnmanagedProduct() async throws {
        let delegate = CountingDelegate(policy: .finish)
        let finishes = TestSignal()
        let snapshot = makeSnapshot(
            id: 72,
            productID: "test.consumable.owned",
            productType: .consumable
        )
        let fixture = TestSourceFixture()
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        let outcome = try await store.process(
            .verified(
                makeEnvelope(snapshot: snapshot) {
                    await finishes.send()
                }
            )
        )

        #expect(outcome == .completed(snapshot))
        #expect(await delegate.decisionCount() == 1)
        #expect(await finishes.value() == 1)
        #expect(store.activeEntitlements == [])
        try await store.close()
    }

    @MainActor
    @Test("automatic policy rejects unmanaged products without finishing")
    func automaticRejectsUnmanagedProduct() async throws {
        let fixture = TestSourceFixture()
        let finishes = TestSignal()
        let snapshot = makeSnapshot(
            id: 8,
            productID: "test.consumable",
            productType: .consumable
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await store.waitForInitialReadiness()

        do {
            _ = try await store.process(
                .verified(
                    makeEnvelope(snapshot: snapshot) {
                        await finishes.send()
                    }
                )
            )
            Issue.record("An unmanaged product was finished automatically.")
        } catch StoreTransactionError.unhandledTransaction(
            productID: let productID,
            productType: let productType
        ) {
            #expect(productID == snapshot.productID)
            #expect(productType == .consumable)
        }
        #expect(await finishes.value() == 0)
        try await store.close()
    }

    @MainActor
    @Test("startup failure commits state before notifying the delegate")
    func failureNotificationFollowsStateCommit() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let holder = TransactionStoreHolder<TestEntitlement>()
        let delegate = StateReadingDelegate(holder: holder)
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        holder.set(store)

        try await query.waitForRequest(1)
        await query.fail(TestFailure())
        await #expect(throws: TestFailure.self) {
            try await store.waitForInitialReadiness()
        }
        try await delegate.waitForFailure()

        #expect(await delegate.observedFailedState())
        try await store.close()
    }

    @MainActor
    @Test("close seals new admission, drains accepted work, and is shared")
    func closeDrainsAcceptedWork() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await query.waitForRequest(1)
        await query.succeed([])
        try await store.waitForInitialReadiness()

        let refresh = Task { @MainActor in
            try await store.refreshEntitlements()
        }
        try await query.waitForRequest(2)
        let firstClose = Task { @MainActor in try await store.close() }
        let secondClose = Task { @MainActor in try await store.close() }

        await store.waitUntilClosing()
        do {
            _ = try await store.refreshEntitlements()
            Issue.record("Closing store accepted a new refresh.")
        } catch StoreTransactionError.closing {}

        await query.succeed([])
        _ = try await refresh.value
        try await firstClose.value
        try await secondClose.value

        do {
            _ = try await store.refreshEntitlements()
            Issue.record("Closed store accepted a new refresh.")
        } catch StoreTransactionError.closed {}
    }
}

private actor CountingDelegate: TransactionStoreDelegate {
    private let policy: StoreTransactionHandlingPolicy
    private var decisions = 0

    init(policy: StoreTransactionHandlingPolicy) {
        self.policy = policy
    }

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        decisions += 1
        return policy
    }

    func decisionCount() -> Int {
        decisions
    }
}

private actor RetryDecisionDelegate: TransactionStoreDelegate {
    private var decisions = 0

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        decisions += 1
        if decisions == 1 {
            throw TestFailure()
        }
        return .automatic
    }

    func decisionCount() -> Int {
        decisions
    }
}

private actor StateReadingDelegate: TransactionStoreDelegate {
    private let holder: TransactionStoreHolder<TestEntitlement>
    private let failure = TestSignal()
    private var sawFailedState = false

    init(holder: TransactionStoreHolder<TestEntitlement>) {
        self.holder = holder
    }

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        sawFailedState = await MainActor.run {
            guard case .failed = holder.get().entitlementStatus else {
                return false
            }
            return true
        }
        await self.failure.send()
    }

    func waitForFailure() async throws {
        try await failure.wait(for: 1)
    }

    func observedFailedState() -> Bool {
        sawFailedState
    }
}
