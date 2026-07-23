import Foundation
import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Unrecognized subscription handling", .timeLimit(.minutes(1)))
struct UnrecognizedSubscriptionTests {
    @MainActor
    @Test("the default policy leaves an unrecognized subscription unfinished")
    func defaultPolicyLeavesUnfinished() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let finishes = TestSignal()
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 401,
            revision: "unknown-default"
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        let outcome = try await store.process(
            .verified(
                makeEnvelope(snapshot: snapshot) {
                    await finishes.send()
                }
            )
        )

        #expect(outcome == .leftUnfinished(snapshot))
        #expect(await finishes.value() == 0)
        #expect(await generalDelegate.decisionCount() == 0)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [])
        try await store.close()
    }

    @MainActor
    @Test("leave policy is reused without finishing a later delivery")
    func leavePolicyIsReused() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let unrecognizedDelegate = RecordingUnrecognizedDelegate(
            policy: .leaveUnfinished
        )
        let finishes = TestSignal()
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 402,
            revision: "unknown-leave"
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await finishes.send()
            }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        #expect(try await store.process(delivery) == .leftUnfinished(snapshot))
        #expect(try await store.process(delivery) == .leftUnfinished(snapshot))

        #expect(await unrecognizedDelegate.decisionCount() == 1)
        #expect(await generalDelegate.decisionCount() == 0)
        #expect(await finishes.value() == 0)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [])
        try await store.close()
    }

    @MainActor
    @Test("finish policy completes without granting an entitlement")
    func finishPolicyCompletesWithoutEntitlement() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let unrecognizedDelegate = RecordingUnrecognizedDelegate(
            policy: .finish
        )
        let finishes = TestSignal()
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 403,
            revision: "unknown-finish"
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        let outcome = try await store.process(
            .verified(
                makeEnvelope(snapshot: snapshot) {
                    await finishes.send()
                }
            )
        )

        #expect(outcome == .completed(snapshot))
        #expect(await unrecognizedDelegate.decisionCount() == 1)
        #expect(await generalDelegate.decisionCount() == 0)
        #expect(await finishes.value() == 1)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [])
        try await store.close()
    }

    @MainActor
    @Test("treat-as policy completes and projects the selected entitlement")
    func treatAsPolicyProjectsEntitlement() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let unrecognizedDelegate = RecordingUnrecognizedDelegate(
            policy: .treatAs(.tier1)
        )
        let finishes = TestSignal()
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 404,
            revision: "unknown-treat-as"
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        let outcome = try await store.process(
            .verified(
                makeEnvelope(snapshot: snapshot) {
                    await finishes.send()
                }
            )
        )

        #expect(outcome == .completed(snapshot))
        #expect(await unrecognizedDelegate.decisionCount() == 1)
        #expect(await generalDelegate.decisionCount() == 0)
        #expect(await finishes.value() == 1)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("a thrown policy is transient, preserves ready state, and retries")
    func thrownPolicyPreservesReadyStateAndRetries() async throws {
        let previous = makeSubscriptionSnapshot(
            id: 405,
            productID: .tier2Monthly
        )
        let replacement = makeUnrecognizedSubscriptionSnapshot(
            id: 406,
            revision: "unknown-retry"
        )
        let current = EntitlementValueSource([previous])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let unrecognizedDelegate = RecordingUnrecognizedDelegate {
            _, attempt in
            if attempt == 1 {
                throw TestFailure()
            }
            return .treatAs(.tier1)
        }
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [replacement])

        await #expect(throws: TestFailure.self) {
            _ = try await store.refreshEntitlements()
        }

        guard case .ready = store.entitlementStatus else {
            Issue.record("A transient policy failure discarded ready state.")
            try await store.close()
            return
        }
        #expect(store.entitlements?.transactions == [previous])
        #expect(store.activeEntitlements == [.tier2])
        #expect(await unrecognizedDelegate.decisionCount() == 1)

        _ = try await store.refreshEntitlements()

        #expect(store.entitlements?.transactions == [replacement])
        #expect(store.activeEntitlements == [.tier1])
        #expect(await unrecognizedDelegate.decisionCount() == 2)
        try await store.close()
    }

    @MainActor
    @Test(
        "known, retired, and out-of-group transactions bypass the unrecognized delegate"
    )
    func otherClassificationsBypassUnrecognizedDelegate() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let unrecognizedDelegate = RecordingUnrecognizedDelegate(
            policy: .treatAs(.tier1)
        )
        let finishes = TestSignal()
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()

        let known = makeSubscriptionSnapshot(
            id: 407,
            productID: .tier2Monthly,
            revision: "known"
        )
        await current.replace(with: [known])
        #expect(
            try await store.process(
                .verified(
                    makeEnvelope(snapshot: known) {
                        await finishes.send()
                    }
                )
            ) == .completed(known)
        )
        #expect(store.activeEntitlements == [.tier2])

        let retired = makeUnrecognizedSubscriptionSnapshot(
            id: 408,
            revision: "retired",
            isUpgraded: true
        )
        await current.replace(with: [retired])
        #expect(
            try await store.process(
                .verified(
                    makeEnvelope(snapshot: retired) {
                        await finishes.send()
                    }
                )
            ) == .completed(retired)
        )
        #expect(store.activeEntitlements == [])

        let outOfGroup = makeUnrecognizedSubscriptionSnapshot(
            id: 409,
            revision: "out-of-group",
            subscriptionGroupID: "test.subscription.other-group"
        )
        await current.replace(with: [outOfGroup])
        #expect(
            try await store.process(
                .verified(
                    makeEnvelope(snapshot: outOfGroup) {
                        await finishes.send()
                    }
                )
            ) == .completed(outOfGroup)
        )

        #expect(await unrecognizedDelegate.decisionCount() == 0)
        #expect(await generalDelegate.decisionCount() == 3)
        #expect(await finishes.value() == 3)
        #expect(store.entitlements?.transactions == [outOfGroup])
        #expect(store.activeEntitlements == [])
        try await store.close()
    }

    @MainActor
    @Test("metadata contradictions fail before either delegate is called")
    func metadataContradictionBypassesDelegates() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let unrecognizedDelegate = RecordingUnrecognizedDelegate(
            policy: .finish
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()

        let contradiction = makeSnapshot(
            id: 410,
            productID: TestPlans.ProductID.tier1Monthly.rawValue,
            productType: .nonConsumable,
            subscriptionGroupID: TestPlans.id.rawValue
        )
        await current.replace(with: [contradiction])

        await #expect(throws: AutoRenewableSubscriptionCatalogError.self) {
            _ = try await store.refreshEntitlements()
        }
        #expect(await unrecognizedDelegate.decisionCount() == 0)
        #expect(await generalDelegate.decisionCount() == 0)
        try await store.close()
    }

    @MainActor
    @Test("same-revision deliveries join and reuse one policy decision")
    func sameRevisionDeliveriesReuseDecision() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let decisionStarted = TestSignal()
        let decisionGate = TestGate()
        let secondAdmitted = TestSignal()
        let unrecognizedDelegate = RecordingUnrecognizedDelegate {
            _, _ in
            await decisionStarted.send()
            try await decisionGate.wait()
            return .treatAs(.tier1)
        }
        let generalDelegate = UnrecognizedTestGeneralDelegate(policy: .finish)
        let finishes = TestSignal()
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 411,
            revision: "unknown-joined"
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await finishes.send()
            }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: generalDelegate,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        let first = Task { @MainActor in
            try await store.process(delivery)
        }
        try await decisionStarted.wait(for: 1)
        let second = Task { @MainActor in
            try await store.process(delivery) {
                await secondAdmitted.send()
            }
        }
        try await secondAdmitted.wait(for: 1)
        #expect(await unrecognizedDelegate.decisionCount() == 1)

        await decisionGate.open()
        #expect(try await first.value == .completed(snapshot))
        #expect(try await second.value == .completed(snapshot))
        #expect(try await store.process(delivery) == .completed(snapshot))

        #expect(await unrecognizedDelegate.decisionCount() == 1)
        #expect(await generalDelegate.decisionCount() == 0)
        #expect(await finishes.value() == 1)
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @Test("different revisions are decided serially and cached for the session")
    func differentRevisionsAreSerialized() async throws {
        let gate = TestGate()
        let delegate = SerializedUnrecognizedDelegate(gate: gate)
        let resolver = UnrecognizedSubscriptionPolicyResolver<TestEntitlement>(
            sessionID: UUID(),
            delegate: delegate
        )
        let firstSnapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 412,
            revision: "serialized-first"
        )
        let secondSnapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 413,
            revision: "serialized-second"
        )

        async let first = resolver.policy(for: firstSnapshot)
        async let second = resolver.policy(for: secondSnapshot)
        try await delegate.waitForDecision(1)

        #expect(await delegate.maximumConcurrentDecisionCount() == 1)
        await gate.open()
        let policies = try await (first, second)

        #expect(policies.0 == .finish)
        #expect(policies.1 == .finish)
        #expect(await delegate.decisionCount() == 2)
        #expect(await delegate.maximumConcurrentDecisionCount() == 1)
        #expect(try await resolver.policy(for: firstSnapshot) == .finish)
        #expect(await delegate.decisionCount() == 2)
        await resolver.sealAndDrain()
    }

    @MainActor
    @Test("unrecognized policy callbacks reject same-store reentrancy")
    func callbackReentrancyIsRejected() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let holder = TransactionStoreHolder<TestEntitlement>()
        let unrecognizedDelegate = ReentrantUnrecognizedDelegate(holder: holder)
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 414,
            revision: "unknown-reentrant"
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        holder.set(store)
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        #expect(
            try await store.process(
                .verified(makeEnvelope(snapshot: snapshot))
            ) == .completed(snapshot)
        )

        #expect(await unrecognizedDelegate.sawReentrantError())
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("close drains a policy decision before releasing its delegate")
    func closeDrainsAndReleasesDelegate() async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let decisionStarted = TestSignal()
        let decisionGate = TestGate()
        let delegateDeinitialized = TestSignal()
        var token: UnrecognizedDelegateLifetimeToken? =
            UnrecognizedDelegateLifetimeToken(signal: delegateDeinitialized)
        weak let weakToken = token
        var unrecognizedDelegate: RetainedUnrecognizedDelegate? =
            RetainedUnrecognizedDelegate(
                token: token!,
                started: decisionStarted,
                gate: decisionGate
            )
        let finishes = TestSignal()
        let snapshot = makeUnrecognizedSubscriptionSnapshot(
            id: 415,
            revision: "unknown-close"
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            unrecognizedSubscriptionDelegate: unrecognizedDelegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        let processing = Task { @MainActor in
            try await store.process(
                .verified(
                    makeEnvelope(snapshot: snapshot) {
                        await finishes.send()
                    }
                )
            )
        }
        try await decisionStarted.wait(for: 1)
        unrecognizedDelegate = nil
        token = nil

        let closeCompleted = TestSignal()
        let close = Task { @MainActor in
            try await store.close()
            await closeCompleted.send()
        }
        await store.waitUntilClosing()

        #expect(await closeCompleted.value() == 0)
        #expect(weakToken != nil)

        await decisionGate.open()
        #expect(try await processing.value == .completed(snapshot))
        try await close.value
        try await delegateDeinitialized.wait(for: 1)

        #expect(await finishes.value() == 1)
        #expect(await closeCompleted.value() == 1)
        #expect(weakToken == nil)
    }
}

private typealias TestUnrecognizedPolicy =
    UnrecognizedSubscriptionPolicy<TestEntitlement>

private actor RecordingUnrecognizedDelegate:
    UnrecognizedSubscriptionDelegate
{
    typealias Entitlement = TestEntitlement

    private let decide:
        @Sendable (StoreTransactionSnapshot, Int) async throws
        -> TestUnrecognizedPolicy
    private var transactions: [StoreTransactionSnapshot] = []

    init(policy: TestUnrecognizedPolicy) {
        decide = { _, _ in policy }
    }

    init(
        decide:
            @escaping @Sendable (StoreTransactionSnapshot, Int) async throws
            -> TestUnrecognizedPolicy
    ) {
        self.decide = decide
    }

    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> TestUnrecognizedPolicy {
        transactions.append(transaction)
        return try await decide(transaction, transactions.count)
    }

    func decisionCount() -> Int {
        transactions.count
    }
}

private actor UnrecognizedTestGeneralDelegate: TransactionStoreDelegate {
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

private actor SerializedUnrecognizedDelegate:
    UnrecognizedSubscriptionDelegate
{
    typealias Entitlement = TestEntitlement

    private let gate: TestGate
    private let started = TestSignal()
    private var decisions = 0
    private var concurrentDecisions = 0
    private var maximumConcurrentDecisions = 0

    init(gate: TestGate) {
        self.gate = gate
    }

    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> TestUnrecognizedPolicy {
        decisions += 1
        concurrentDecisions += 1
        maximumConcurrentDecisions = max(
            maximumConcurrentDecisions,
            concurrentDecisions
        )
        await started.send()
        try await gate.wait()
        concurrentDecisions -= 1
        return .finish
    }

    func waitForDecision(_ count: Int) async throws {
        try await started.wait(for: count)
    }

    func decisionCount() -> Int {
        decisions
    }

    func maximumConcurrentDecisionCount() -> Int {
        maximumConcurrentDecisions
    }
}

private actor ReentrantUnrecognizedDelegate:
    UnrecognizedSubscriptionDelegate
{
    typealias Entitlement = TestEntitlement

    private let holder: TransactionStoreHolder<TestEntitlement>
    private var rejected = false

    init(holder: TransactionStoreHolder<TestEntitlement>) {
        self.holder = holder
    }

    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> TestUnrecognizedPolicy {
        do {
            _ = try await holder.get().refreshEntitlements()
        } catch StoreTransactionError.reentrantOperation(
            operation: .refreshEntitlements
        ) {
            rejected = true
        }
        return .treatAs(.tier1)
    }

    func sawReentrantError() -> Bool {
        rejected
    }
}

private actor RetainedUnrecognizedDelegate:
    UnrecognizedSubscriptionDelegate
{
    typealias Entitlement = TestEntitlement

    private let token: UnrecognizedDelegateLifetimeToken
    private let started: TestSignal
    private let gate: TestGate

    init(
        token: UnrecognizedDelegateLifetimeToken,
        started: TestSignal,
        gate: TestGate
    ) {
        self.token = token
        self.started = started
        self.gate = gate
    }

    func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> TestUnrecognizedPolicy {
        _ = token
        await started.send()
        try await gate.wait()
        return .finish
    }
}

private final class UnrecognizedDelegateLifetimeToken: Sendable {
    private let signal: TestSignal

    init(signal: TestSignal) {
        self.signal = signal
    }

    deinit {
        let signal = signal
        Task { await signal.send() }
    }
}

private func makeUnrecognizedSubscriptionSnapshot(
    id: UInt64,
    revision: String,
    isUpgraded: Bool = false,
    subscriptionGroupID: String = TestPlans.id.rawValue
) -> StoreTransactionSnapshot {
    makeSnapshot(
        id: id,
        productID: "test.subscription.unrecognized",
        productType: .autoRenewable,
        subscriptionGroupID: subscriptionGroupID,
        jws: revision,
        isUpgraded: isUpgraded
    )
}
