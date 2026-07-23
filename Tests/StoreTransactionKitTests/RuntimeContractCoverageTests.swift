import Foundation
import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Runtime contract coverage", .timeLimit(.minutes(1)))
struct RuntimeContractCoverageTests {
    @MainActor
    @Test("subscription status waits for readiness and close drains its publication")
    func subscriptionStatusReadinessAndCloseDrain() async throws {
        let query = ControlledEntitlementQuery()
        let snapshot = makeSubscriptionSnapshot(
            id: 301,
            productID: .tier1Monthly
        )
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )

        try await query.waitForRequest(1)
        fixture.subscriptionStatusUpdates.yield()
        try await fixture.subscriptionStatusDeliveryCount.wait(for: 1)
        #expect(await fixture.entitlementQueryCount.value() == 1)

        await query.succeed([])
        try await store.waitForInitialReadiness()
        try await query.waitForRequest(2)

        let closeCompleted = TestSignal()
        let close = Task { @MainActor in
            try await store.close()
            await closeCompleted.send()
        }
        await store.waitUntilClosing()
        #expect(await closeCompleted.value() == 0)

        await query.succeed([snapshot])
        try await close.value

        #expect(await closeCompleted.value() == 1)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
    }

    @MainActor
    @Test("subscription status handles revocation before publishing removal")
    func subscriptionStatusRevocationOrdering() async throws {
        let active = makeSnapshot(
            id: 302,
            productID: TestPlans.ProductID.tier1Monthly.rawValue,
            productType: .autoRenewable,
            subscriptionGroupID: TestPlans.id.rawValue,
            jws: "active-302"
        )
        let revoked = makeSnapshot(
            id: active.id,
            productID: active.productID,
            productType: .autoRenewable,
            subscriptionGroupID: TestPlans.id.rawValue,
            signedDate: Date(timeIntervalSince1970: 400),
            jws: "revoked-302",
            revocationDate: Date(timeIntervalSince1970: 399)
        )
        let current = EntitlementValueSource([active])
        let unfinished = UnfinishedValueSource()
        let decisionStarted = TestSignal()
        let decisionFinished = TestSignal()
        let decisionGate = NonCancellableGate()
        let delegate = GatedPolicyDelegate(
            started: decisionStarted,
            finished: decisionFinished,
            gate: decisionGate
        )
        let finishes = TestSignal()
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() },
            queryUnfinished: { await unfinished.read() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        await current.replace(with: [])
        await unfinished.replace(with: [
            .verified(
                makeEnvelope(snapshot: revoked, revision: "revoked-302") {
                    await finishes.send()
                    await unfinished.replace(with: [])
                }
            )
        ])
        fixture.subscriptionStatusUpdates.yield()
        try await fixture.subscriptionStatusDeliveryCount.wait(for: 1)
        try await decisionStarted.wait(for: 1)

        #expect(store.activeEntitlements == [.tier1])
        #expect(await finishes.value() == 0)

        let close = Task { @MainActor in try await store.close() }
        await store.waitUntilClosing()
        decisionGate.open()
        try await close.value

        #expect(await decisionFinished.value() == 1)
        #expect(await finishes.value() == 1)
        #expect(await delegate.decisionCount() == 1)
        #expect(store.entitlements?.transactions.isEmpty == true)
        #expect(store.activeEntitlements == [])
    }

    @Test("restore reservations coalesce, expose one failure, and retry independently")
    func restoreCoordinatorCoalescingAndRetry() async throws {
        let synchronization = ControlledSynchronization()
        let failures = FailureReporterDispatcher()
        let entitlements = EntitlementRefreshCoordinator<TestEntitlement>(
            query: { _ in
                CurrentEntitlementReconciliation(
                    snapshots: [],
                    causalClaims: [],
                    diagnostics: []
                )
            },
            project: {
                (_: StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
                    -> Set<TestEntitlement> in
                []
            },
            didComplete: { _ in },
            failures: failures
        )
        let coordinator = RestoreCoordinator(
            synchronize: { try await synchronization.run() },
            entitlements: entitlements
        )

        let first = await coordinator.reserve()
        try await synchronization.waitForAttempt(1)
        let second = await coordinator.reserve()

        #expect(first.role == .owner)
        #expect(second.role == .observer)
        #expect(first.receipt === second.receipt)
        #expect(first.reportingAuthority === second.reportingAuthority)

        await synchronization.failNext(TestFailure())
        for receipt in [first.receipt, second.receipt] {
            do {
                _ = try await receipt.terminalValue()
                Issue.record("A failed restore reservation unexpectedly succeeded.")
            } catch let failure as RestoreCoordinatorFailure {
                #expect(failure.underlyingError is TestFailure)
                #expect(!failure.synchronized)
            }
        }

        let retry = await coordinator.reserve()
        try await synchronization.waitForAttempt(2)
        await synchronization.succeedNext()
        let publication = try await retry.receipt.terminalValue()

        #expect(retry.role == .owner)
        #expect(retry.receipt !== first.receipt)
        #expect(publication.entitlements.transactions.isEmpty)
        #expect(await synchronization.attemptCount() == 2)
        await entitlements.sealAndDrain()
        await failures.sealAndDrain()
    }

    @MainActor
    @Test("an abandoned restore reports once and a later restore retries synchronization")
    func abandonedRestoreReportsOnceAndRetries() async throws {
        let synchronization = ControlledSynchronization()
        let delegate = RecordingFailureDelegate()
        let fixture = TestSourceFixture(
            synchronize: { try await synchronization.run() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        let first = Task { @MainActor in try await store.restorePurchases() }
        try await synchronization.waitForAttempt(1)
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }

        await synchronization.failNext(TestFailure())
        try await delegate.waitForFailures(1)

        let retry = Task { @MainActor in try await store.restorePurchases() }
        try await synchronization.waitForAttempt(2)
        await synchronization.succeedNext()
        let restored = try await retry.value

        let recorded = await delegate.failures()
        #expect(recorded.count == 1)
        #expect(
            recorded[0].source
                == .abandonedDirectOperation(.restorePurchases)
        )
        #expect(recorded[0].underlyingError is TestFailure)
        #expect(restored.transactions.isEmpty)
        #expect(await synchronization.attemptCount() == 2)
        try await store.close()
    }

    @Test(
        "coalesced direct operations preserve caller errors and one abandoned report"
    )
    func coalescedDirectOperationFailureOwnership() async throws {
        let query = ControlledEntitlementQuery()
        let reservations = TestCounterSignal()
        let synchronizations = TestCounterSignal()
        let finishes = TestCounterSignal()
        let delegate = RecordingFailureDelegate()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() },
            synchronize: { synchronizations.send() }
        )
        let lifecycle = TransactionStoreLifecycle()
        let runtime = StoreTransactionRuntime(
            sessionID: UUID(),
            source: fixture.source,
            lifecycle: lifecycle,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate,
            entitlementOutcome: { _ in },
            entitlementReservationDidEnqueue: {
                reservations.send()
            }
        )
        runtime.start()

        try await query.waitForRequest(1)
        #expect(reservations.value() == 1)

        let firstSnapshot = makeSubscriptionSnapshot(
            id: 306,
            productID: .tier1Monthly,
            revision: "coalesced-first"
        )
        let firstProcess = Task {
            try await runtime.process(
                .verified(
                    makeEnvelope(
                        snapshot: firstSnapshot,
                        revision: "coalesced-first"
                    ) {
                        finishes.send()
                    }
                ),
                leases: try lifecycle.beginOperation()
            )
        }
        let firstRestore = Task {
            try await runtime.restorePurchases(
                leases: try lifecycle.beginOperation()
            )
        }
        let firstRefresh = Task {
            try await runtime.currentEntitlements(
                leases: try lifecycle.beginOperation()
            )
        }

        try await reservations.wait(for: 4)
        #expect(finishes.value() == 1)
        #expect(synchronizations.value() == 1)

        await query.succeed([])
        try await runtime.waitForInitialReadiness()
        try await query.waitForRequest(2)
        #expect(await fixture.entitlementQueryCount.value() == 2)
        await query.fail(CoalescedRefreshFailure(batch: 1))

        do {
            _ = try await firstProcess.value
            Issue.record("The process caller unexpectedly succeeded.")
        } catch StoreTransactionError.entitlementRefreshFailed(
            after: .finishedTransaction(let transaction),
            underlyingError: let error
        ) {
            #expect(transaction == firstSnapshot)
            #expect((error as? CoalescedRefreshFailure)?.batch == 1)
        } catch {
            Issue.record("The process caller received an unexpected error: \(error)")
        }

        do {
            _ = try await firstRestore.value
            Issue.record("The restore caller unexpectedly succeeded.")
        } catch StoreTransactionError.entitlementRefreshFailed(
            after: .synchronizedPurchases,
            underlyingError: let error
        ) {
            #expect((error as? CoalescedRefreshFailure)?.batch == 1)
        } catch {
            Issue.record("The restore caller received an unexpected error: \(error)")
        }

        do {
            _ = try await firstRefresh.value
            Issue.record("The refresh caller unexpectedly succeeded.")
        } catch let error as CoalescedRefreshFailure {
            #expect(error.batch == 1)
        } catch {
            Issue.record("The refresh caller received an unexpected error: \(error)")
        }
        #expect((await delegate.failures()).isEmpty)

        let separatingRefresh = Task {
            try await runtime.currentEntitlements(
                leases: try lifecycle.beginOperation()
            )
        }
        try await reservations.wait(for: 5)
        try await query.waitForRequest(3)

        let secondSnapshot = makeSubscriptionSnapshot(
            id: 307,
            productID: .tier2Monthly,
            revision: "coalesced-abandoned"
        )
        let secondProcess = Task {
            try await runtime.process(
                .verified(
                    makeEnvelope(
                        snapshot: secondSnapshot,
                        revision: "coalesced-abandoned"
                    ) {
                        finishes.send()
                    }
                ),
                leases: try lifecycle.beginOperation()
            )
        }
        let secondRestore = Task {
            try await runtime.restorePurchases(
                leases: try lifecycle.beginOperation()
            )
        }
        let secondRefresh = Task {
            try await runtime.currentEntitlements(
                leases: try lifecycle.beginOperation()
            )
        }

        try await reservations.wait(for: 8)
        #expect(finishes.value() == 2)
        #expect(synchronizations.value() == 2)

        secondProcess.cancel()
        secondRestore.cancel()
        secondRefresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await secondProcess.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await secondRestore.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await secondRefresh.value
        }

        await query.succeed([])
        _ = try await separatingRefresh.value
        try await query.waitForRequest(4)
        #expect(await fixture.entitlementQueryCount.value() == 4)
        await query.fail(CoalescedRefreshFailure(batch: 2))
        try await delegate.waitForFailures(1)

        await lifecycle.close {
            await runtime.shutdown()
        }

        let failures = await delegate.failures()
        #expect(failures.count == 1)
        #expect(
            (failures.first?.underlyingError as? CoalescedRefreshFailure)?
                .batch == 2
        )
        if let source = failures.first?.source {
            guard case .abandonedDirectOperation(let operation) = source else {
                Issue.record("The failed batch had no abandoned direct owner.")
                return
            }
            #expect(
                [
                    StoreTransactionOperation.processPurchase,
                    .refreshEntitlements,
                    .restorePurchases,
                ].contains(operation)
            )
        }
        #expect(reservations.value() == 8)
        #expect(await fixture.entitlementQueryCount.value() == 4)
    }

    @MainActor
    @Test("immediate purchase outcomes perform no transaction work")
    func immediatePurchaseOutcomes() async throws {
        let delegate = RecordingPolicyDelegate()
        let fixture = TestSourceFixture()
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        #expect(try await store.process(.pending) == .pending)
        #expect(try await store.process(.userCancelled) == .userCancelled)
        #expect(await delegate.decisionCount() == 0)
        #expect(await fixture.entitlementQueryCount.value() == 1)
        try await store.close()
    }

    @MainActor
    @Test("cancellation before admission starts no operation-specific work")
    func cancellationBeforeAdmission() async throws {
        let delegate = RecordingPolicyDelegate()
        let historyCalls = TestSignal()
        let synchronizationCalls = TestSignal()
        let fixture = TestSourceFixture(
            history: { _ in
                await historyCalls.send()
                return []
            },
            synchronize: { await synchronizationCalls.send() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        try await expectCancellationBeforeInvocation {
            try await store.process(.pending)
        }
        try await expectCancellationBeforeInvocation {
            try await store.refreshEntitlements()
        }
        try await expectCancellationBeforeInvocation {
            try await store.history(for: "cancelled.history")
        }
        try await expectCancellationBeforeInvocation {
            try await store.restorePurchases()
        }

        #expect(await delegate.decisionCount() == 0)
        #expect(await fixture.entitlementQueryCount.value() == 1)
        #expect(await historyCalls.value() == 0)
        #expect(await synchronizationCalls.value() == 0)
        try await store.close()
    }

    @MainActor
    @Test("distinct revisions of one transaction are processed independently")
    func distinctRevisionsProcessRevocation() async throws {
        let active = makeSnapshot(
            id: 303,
            productID: TestPlans.ProductID.tier2Monthly.rawValue,
            productType: .autoRenewable,
            subscriptionGroupID: TestPlans.id.rawValue,
            jws: "active-303"
        )
        let revoked = makeSnapshot(
            id: active.id,
            productID: active.productID,
            productType: .autoRenewable,
            subscriptionGroupID: TestPlans.id.rawValue,
            signedDate: Date(timeIntervalSince1970: 500),
            jws: "revoked-303",
            revocationDate: Date(timeIntervalSince1970: 499)
        )
        let current = EntitlementValueSource([])
        let delegate = RecordingPolicyDelegate()
        let finishes = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        await current.replace(with: [active])
        _ = try await store.process(
            .verified(
                makeEnvelope(snapshot: active, revision: "active-303") {
                    await finishes.append("active")
                }
            )
        )
        await current.replace(with: [])
        _ = try await store.process(
            .verified(
                makeEnvelope(snapshot: revoked, revision: "revoked-303") {
                    await finishes.append("revoked")
                }
            )
        )

        #expect(await delegate.decisionCount() == 2)
        #expect(await finishes.snapshot() == ["active", "revoked"])
        #expect(store.entitlements?.transactions.isEmpty == true)
        #expect(store.activeEntitlements == [])
        try await store.close()
    }

    @Test("completed revision cache evicts its oldest bounded entry")
    func completedRevisionCacheEviction() {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)
        var cache = CompletedRevisionCache(capacity: 2)

        cache.insert(first, state: .satisfied)
        cache.insert(second, state: .needsRefresh)
        cache.insert(first, state: .needsRefresh)
        cache.insert(third, state: .satisfied)

        #expect(cache.state(for: first) == nil)
        guard case .needsRefresh = cache.state(for: second) else {
            Issue.record("The second completed revision was unexpectedly evicted.")
            return
        }
        guard case .satisfied = cache.state(for: third) else {
            Issue.record("The newest completed revision was not retained.")
            return
        }
    }

    @MainActor
    @Test("a successful refresh recovers failed startup state")
    func failedStartupRecoversToReady() async throws {
        let query = ControlledEntitlementQuery()
        let snapshot = makeSubscriptionSnapshot(
            id: 304,
            productID: .tier1Yearly
        )
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )

        try await query.waitForRequest(1)
        await query.fail(TestFailure())
        await #expect(throws: TestFailure.self) {
            try await store.waitForInitialReadiness()
        }
        guard case .failed = store.entitlementStatus else {
            Issue.record("The failed startup was not observable.")
            try await store.close()
            return
        }
        #expect(store.entitlements == nil)
        #expect(store.activeEntitlements == nil)

        let refresh = Task { @MainActor in try await store.refreshEntitlements() }
        try await query.waitForRequest(2)
        await query.succeed([snapshot])
        _ = try await refresh.value

        guard case .ready = store.entitlementStatus else {
            Issue.record("A successful refresh did not recover readiness.")
            try await store.close()
            return
        }
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("close drains failure notification, releases delegate, and admits no later callback")
    func closeDrainsFailureNotificationAndDelegate() async throws {
        let callbackStarted = TestSignal()
        let callbackFinished = TestSignal()
        let callbackGate = NonCancellableGate()
        let callbackCount = TestSignal()
        let delegateDeinitialized = TestSignal()
        var token: LifetimeToken? = LifetimeToken(signal: delegateDeinitialized)
        weak let weakToken = token
        var delegate: GatedFailureDelegate? = GatedFailureDelegate(
            token: token!,
            started: callbackStarted,
            finished: callbackFinished,
            calls: callbackCount,
            gate: callbackGate
        )
        let fixture = TestSourceFixture()
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()

        fixture.updates.yield(
            .unverified(
                revision: Data("close-failure".utf8),
                error: TestFailure()
            )
        )
        try await callbackStarted.wait(for: 1)
        delegate = nil
        token = nil

        let closeCompleted = TestSignal()
        let close = Task { @MainActor in
            try await store.close()
            await closeCompleted.send()
        }
        await store.waitUntilClosing()
        #expect(await closeCompleted.value() == 0)
        #expect(weakToken != nil)

        callbackGate.open()
        try await close.value
        try await delegateDeinitialized.wait(for: 1)

        #expect(await callbackFinished.value() == 1)
        #expect(await closeCompleted.value() == 1)
        #expect(await callbackCount.value() == 1)
        #expect(weakToken == nil)

        fixture.updates.yield(
            .unverified(
                revision: Data("late-failure".utf8),
                error: TestFailure()
            )
        )
        #expect(await callbackCount.value() == 1)
    }

    @MainActor
    @Test("deinit drains a suspended decision before releasing its delegate")
    func deinitDrainsDecision() async throws {
        let decisionStarted = TestSignal()
        let decisionFinished = TestSignal()
        let decisionGate = NonCancellableGate()
        let delegateDeinitialized = TestSignal()
        var token: LifetimeToken? = LifetimeToken(signal: delegateDeinitialized)
        weak let weakToken = token
        var delegate: GatedPolicyDelegate? = GatedPolicyDelegate(
            token: token!,
            started: decisionStarted,
            finished: decisionFinished,
            gate: decisionGate
        )
        let finishes = TestSignal()
        let fixture = TestSourceFixture()
        var store: TransactionStore<TestEntitlement>? = TransactionStore(
            source: fixture.source,
            lifecycle: TransactionStoreLifecycle(),
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store!.waitForInitialReadiness()
        fixture.updates.yield(
            .verified(
                makeEnvelope(
                    snapshot: makeSubscriptionSnapshot(
                        id: 305,
                        productID: .tier1Monthly
                    )
                ) {
                    await finishes.send()
                }
            )
        )
        try await decisionStarted.wait(for: 1)

        weak let weakStore = store
        delegate = nil
        token = nil
        store = nil

        #expect(weakStore == nil)
        #expect(weakToken != nil)
        #expect(await finishes.value() == 0)

        decisionGate.open()
        try await decisionFinished.wait(for: 1)
        try await delegateDeinitialized.wait(for: 1)

        #expect(await finishes.value() == 1)
        #expect(weakToken == nil)
    }

    @MainActor
    @Test("deinit retains runtime while admitted restore synchronization is suspended")
    func deinitDrainsRestoreSynchronization() async throws {
        let synchronization = ControlledSynchronization()
        let delegateDeinitialized = TestSignal()
        var token: LifetimeToken? = LifetimeToken(signal: delegateDeinitialized)
        weak let weakToken = token
        var delegate: TokenHoldingDelegate? = TokenHoldingDelegate(token: token!)
        let fixture = TestSourceFixture(
            synchronize: { try await synchronization.run() }
        )
        var store: TransactionStore<TestEntitlement>? = TransactionStore(
            source: fixture.source,
            lifecycle: TransactionStoreLifecycle(),
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store!.waitForInitialReadiness()

        var restore: Task<StoreEntitlements, any Error>? = {
            let admittedStore = store!
            return Task { @MainActor in
                try await admittedStore.restorePurchases()
            }
        }()
        try await synchronization.waitForAttempt(1)
        restore!.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await restore!.value
        }
        restore = nil

        weak let weakStore = store
        delegate = nil
        token = nil
        store = nil

        #expect(weakStore == nil)
        #expect(weakToken != nil)

        await synchronization.succeedNext()
        try await delegateDeinitialized.wait(for: 1)
        #expect(weakToken == nil)
    }

    @MainActor
    @Test("deinit drains a suspended failure notification")
    func deinitDrainsFailureNotification() async throws {
        let callbackStarted = TestSignal()
        let callbackFinished = TestSignal()
        let callbackGate = NonCancellableGate()
        let callbackCount = TestSignal()
        let delegateDeinitialized = TestSignal()
        var token: LifetimeToken? = LifetimeToken(signal: delegateDeinitialized)
        weak let weakToken = token
        var delegate: GatedFailureDelegate? = GatedFailureDelegate(
            token: token!,
            started: callbackStarted,
            finished: callbackFinished,
            calls: callbackCount,
            gate: callbackGate
        )
        let fixture = TestSourceFixture()
        var store: TransactionStore<TestEntitlement>? = TransactionStore(
            source: fixture.source,
            lifecycle: TransactionStoreLifecycle(),
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store!.waitForInitialReadiness()
        fixture.updates.yield(
            .unverified(
                revision: Data("deinit-failure".utf8),
                error: TestFailure()
            )
        )
        try await callbackStarted.wait(for: 1)

        weak let weakStore = store
        delegate = nil
        token = nil
        store = nil

        #expect(weakStore == nil)
        #expect(weakToken != nil)

        callbackGate.open()
        try await callbackFinished.wait(for: 1)
        try await delegateDeinitialized.wait(for: 1)

        #expect(await callbackCount.value() == 1)
        #expect(weakToken == nil)
    }
}

@MainActor
private func expectCancellationBeforeInvocation<Output: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> Output
) async throws {
    let waiting = TestSignal()
    let release = ProcessingReceipt<Void>()
    let task = Task { @MainActor in
        await waiting.send()
        _ = try? await release.terminalValue()
        return try await operation()
    }
    try await waiting.wait(for: 1)
    task.cancel()
    release.succeed(())
    do {
        _ = try await task.value
        Issue.record("A pre-cancelled operation unexpectedly succeeded.")
    } catch is CancellationError {
    } catch {
        Issue.record("A pre-cancelled operation threw an unexpected error: \(error)")
    }
}

private final class NonCancellableGate: Sendable {
    private let receipt = ProcessingReceipt<Void>()

    func wait() async {
        _ = try? await receipt.terminalValue()
    }

    func open() {
        receipt.succeed(())
    }
}

private struct CoalescedRefreshFailure: Error, Sendable {
    let batch: Int
}

private actor ControlledSynchronization {
    private var attempts: [ProcessingReceipt<Void>] = []
    private let started = TestSignal()

    func run() async throws {
        let receipt = ProcessingReceipt<Void>()
        attempts.append(receipt)
        await started.send()
        try await receipt.terminalValue()
    }

    func waitForAttempt(_ count: Int) async throws {
        try await started.wait(for: count)
    }

    func succeedNext() {
        precondition(!attempts.isEmpty)
        attempts.removeFirst().succeed(())
    }

    func failNext(_ error: any Error) {
        precondition(!attempts.isEmpty)
        attempts.removeFirst().fail(error)
    }

    func attemptCount() async -> Int {
        await started.value()
    }
}

private actor RecordingPolicyDelegate: TransactionStoreDelegate {
    private var decisions = 0

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        decisions += 1
        return .automatic
    }

    func decisionCount() -> Int {
        decisions
    }
}

private actor GatedPolicyDelegate: TransactionStoreDelegate {
    private let token: LifetimeToken?
    private let started: TestSignal
    private let finished: TestSignal
    private let gate: NonCancellableGate
    private var decisions = 0

    init(
        token: LifetimeToken? = nil,
        started: TestSignal,
        finished: TestSignal,
        gate: NonCancellableGate
    ) {
        self.token = token
        self.started = started
        self.finished = finished
        self.gate = gate
    }

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        _ = token
        decisions += 1
        await started.send()
        await gate.wait()
        await finished.send()
        return .automatic
    }

    func decisionCount() -> Int {
        decisions
    }
}

private actor RecordingFailureDelegate: TransactionStoreDelegate {
    private var recorded: [StoreTransactionBackgroundFailure] = []
    private let signal = TestSignal()

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        recorded.append(failure)
        await signal.send()
    }

    func waitForFailures(_ count: Int) async throws {
        try await signal.wait(for: count)
    }

    func failures() -> [StoreTransactionBackgroundFailure] {
        recorded
    }
}

private actor GatedFailureDelegate: TransactionStoreDelegate {
    private let token: LifetimeToken
    private let started: TestSignal
    private let finished: TestSignal
    private let calls: TestSignal
    private let gate: NonCancellableGate

    init(
        token: LifetimeToken,
        started: TestSignal,
        finished: TestSignal,
        calls: TestSignal,
        gate: NonCancellableGate
    ) {
        self.token = token
        self.started = started
        self.finished = finished
        self.calls = calls
        self.gate = gate
    }

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        _ = token
        await calls.send()
        await started.send()
        await gate.wait()
        await finished.send()
    }
}

private actor TokenHoldingDelegate: TransactionStoreDelegate {
    private let token: LifetimeToken

    init(token: LifetimeToken) {
        self.token = token
    }
}

private final class LifetimeToken: Sendable {
    private let signal: TestSignal

    init(signal: TestSignal) {
        self.signal = signal
    }

    deinit {
        let signal = signal
        Task { await signal.send() }
    }
}
