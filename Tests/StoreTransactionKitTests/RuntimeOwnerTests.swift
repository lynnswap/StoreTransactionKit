import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Runtime owners", .timeLimit(.minutes(1)))
struct RuntimeOwnerTests {
    @MainActor
    @Test("unfinished reconciliation reaches a fixed point before publication")
    func fixedPointReconciliation() async throws {
        let first = makeSubscriptionSnapshot(
            id: 20,
            productID: .tier1Monthly
        )
        let second = makeSubscriptionSnapshot(
            id: 21,
            productID: .tier2Monthly
        )
        let unfinished = UnfinishedValueSource()
        let finishes = UInt64Recorder()
        await unfinished.replace(with: [
            .verified(
                makeEnvelope(snapshot: first) {
                    await finishes.append(first.id)
                    await unfinished.replace(with: [
                        .verified(
                            makeEnvelope(snapshot: second) {
                                await finishes.append(second.id)
                                await unfinished.replace(with: [])
                            }
                        )
                    ])
                }
            )
        ])
        let fixture = TestSourceFixture(
            currentEntitlements: { [first, second] },
            queryUnfinished: { await unfinished.read() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )

        try await store.waitForInitialReadiness()

        #expect(await finishes.snapshot() == [first.id, second.id])
        #expect(store.entitlements?.transactions == [first, second])
        #expect(store.activeEntitlements == [.tier1, .tier2])
        try await store.close()
    }

    @MainActor
    @Test("reconciliation reports every exact decision failure once")
    func reconciliationReportsEveryDecisionFailure() async throws {
        let first = makeSubscriptionSnapshot(
            id: 201,
            productID: .tier1Monthly,
            revision: "failure-201"
        )
        let second = makeSubscriptionSnapshot(
            id: 202,
            productID: .tier2Monthly,
            revision: "failure-202"
        )
        let delegate = FailingDecisionDelegate()
        let fixture = TestSourceFixture(
            queryUnfinished: {
                [
                    .verified(makeEnvelope(snapshot: first)),
                    .verified(makeEnvelope(snapshot: second)),
                ]
            }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )

        await #expect(throws: TransactionDecisionFailure.self) {
            try await store.waitForInitialReadiness()
        }
        try await delegate.waitForFailures(2)
        try await store.close()

        let failures = await delegate.failures()
        #expect(failures.map(\.transactionID) == [first.id, second.id])
        #expect(failures.allSatisfy { $0.source == .unfinished })
        #expect(
            failures.compactMap {
                ($0.underlyingError as? TransactionDecisionFailure)?.id
            } == [first.id, second.id]
        )
    }

    @MainActor
    @Test("verified remainder publishes before verification diagnostics")
    func verificationFailurePublishesRemainder() async throws {
        let snapshot = makeSubscriptionSnapshot(
            id: 22,
            productID: .tier1Monthly
        )
        let holder = TransactionStoreHolder<TestEntitlement>()
        let delegate = StateReadingFailureDelegate(holder: holder)
        let fixture = TestSourceFixture(
            currentEntitlements: { [snapshot] },
            currentEntitlementVerificationFailures: {
                [
                    StoreTransactionVerificationError(
                        underlyingError: TestFailure()
                    )
                ]
            }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        holder.set(store)

        try await store.waitForInitialReadiness()
        try await delegate.waitForFailure()

        #expect(await delegate.observedReadyState())
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test("an abandoned refresh transfers one terminal failure to the background")
    func cancellationTransfersFailureOwnership() async throws {
        let query = ControlledEntitlementQuery()
        let delegate = FailureRecordingDelegate()
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

        let refresh = Task { @MainActor in
            try await store.refreshEntitlements()
        }
        try await query.waitForRequest(2)
        refresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await refresh.value
        }
        await query.fail(TestFailure())
        try await delegate.waitForFailures(1)

        let failures = await delegate.failures()
        #expect(failures.count == 1)
        #expect(
            failures.first?.source
                == .abandonedDirectOperation(.refreshEntitlements)
        )
        #expect(failures.first?.underlyingError is TestFailure)
        try await store.close()
    }

    @MainActor
    @Test("cancellation after unverified delivery admission transfers failure ownership")
    func unverifiedCancellationTransfersFailureOwnership() async throws {
        let delegate = FailureRecordingDelegate()
        let fixture = TestSourceFixture()
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()
        let admitted = TestSignal()
        let release = ProcessingReceipt<Void>()
        let operation = Task { @MainActor in
            try await store.process(
                .unverified(
                    revision: Data("unverified".utf8),
                    error: TestFailure()
                )
            ) {
                await admitted.send()
                _ = try? await release.terminalValue()
            }
        }
        try await admitted.wait(for: 1)

        operation.cancel()
        release.succeed(())

        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        try await delegate.waitForFailures(1)
        try await store.close()
        let failures = await delegate.failures()
        #expect(failures.count == 1)
        #expect(
            failures[0].source
                == .abandonedDirectOperation(.processPurchase)
        )
        #expect(failures[0].underlyingError is TestFailure)
    }

    @MainActor
    @Test("close drains a producer element returned before iteration admission sealed")
    func producerCloseRaceDrainsPublication() async throws {
        let snapshot = makeSubscriptionSnapshot(
            id: 23,
            productID: .tier2Monthly
        )
        let current = EntitlementValueSource([])
        let delegate = GatedDecisionDelegate()
        let finishes = TestSignal()
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: snapshot, revision: "producer-close") {
                    await finishes.send()
                }
            )
        )
        try await delegate.waitUntilDecisionStarts()

        let close = Task { @MainActor in try await store.close() }
        await store.waitUntilClosing()
        let cancelledClose = Task { @MainActor in try await store.close() }
        cancelledClose.cancel()
        await delegate.allowDecision()
        try await close.value
        try await cancelledClose.value

        #expect(await finishes.value() == 1)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier2])
    }

    @MainActor
    @Test("history is all-or-nothing and has deterministic newest-first order")
    func historyOrdering() async throws {
        let oldest = makeSnapshot(
            id: 1,
            purchaseDate: Date(timeIntervalSince1970: 1),
            signedDate: Date(timeIntervalSince1970: 2)
        )
        let newestLowerID = makeSnapshot(
            id: 2,
            purchaseDate: Date(timeIntervalSince1970: 3),
            signedDate: Date(timeIntervalSince1970: 4),
            jws: "b"
        )
        let newestHigherID = makeSnapshot(
            id: 3,
            purchaseDate: Date(timeIntervalSince1970: 3),
            signedDate: Date(timeIntervalSince1970: 4),
            jws: "a"
        )
        let fixture = TestSourceFixture(
            history: { _ in [oldest, newestLowerID, newestHigherID] }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await store.waitForInitialReadiness()

        let history = try await store.history(for: "history.product")

        #expect(history == [newestHigherID, newestLowerID, oldest])
        try await store.close()
    }

    @MainActor
    @Test("restore wraps only a refresh failure that follows successful sync")
    func restoreFailureContext() async throws {
        let query = ControlledEntitlementQuery()
        let syncs = TestSignal()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() },
            synchronize: { await syncs.send() }
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await query.waitForRequest(1)
        await query.succeed([])
        try await store.waitForInitialReadiness()

        let restore = Task { @MainActor in
            try await store.restorePurchases()
        }
        try await query.waitForRequest(2)
        await query.fail(TestFailure())

        do {
            _ = try await restore.value
            Issue.record("Expected a post-sync refresh failure.")
        } catch StoreTransactionError.entitlementRefreshFailed(
            after: .synchronizedPurchases,
            underlyingError: let error
        ) {
            #expect(error is TestFailure)
        }
        #expect(await syncs.value() == 1)
        try await store.close()
    }

    @MainActor
    @Test("synthetic capability errors precede work but closed state takes priority")
    func syntheticOperationGateOrdering() async throws {
        let source = SyntheticStoreTransactionSource(
            currentEntitlements: { [] }
        )
        let store = TransactionStore(
            subscriptionCatalog: testSubscriptionCatalog,
            syntheticSource: source,
            unavailableOperationError: { operation in
                StoreTransactionError.operationUnavailableInOverride(
                    operation: operation
                )
            }
        )
        try await store.waitForInitialReadiness()

        do {
            _ = try await store.history(for: "product")
            Issue.record("Synthetic source unexpectedly queried history.")
        } catch StoreTransactionError.operationUnavailableInOverride(
            operation: .history
        ) {}

        try await store.close()
        do {
            _ = try await store.history(for: "product")
            Issue.record("Closed synthetic store exposed capability error.")
        } catch StoreTransactionError.closed {}
    }

    @MainActor
    @Test("synthetic delivery uses production policy, acknowledgement, and publication")
    func syntheticDeliveryProductionPath() async throws {
        let current = EntitlementValueSource([])
        let syntheticSource = SyntheticStoreTransactionSource(
            currentEntitlements: { await current.read() }
        )
        let snapshot = makeSubscriptionSnapshot(
            id: 24,
            productID: .tier1Yearly,
            revision: "synthetic-24"
        )
        let store = TransactionStore(
            subscriptionCatalog: testSubscriptionCatalog,
            syntheticSource: syntheticSource,
            unavailableOperationError: {
                SyntheticOperationError(operation: $0)
            }
        )
        try await store.waitForInitialReadiness()

        do {
            _ = try await store.history(for: snapshot.productID)
            Issue.record("Synthetic store unexpectedly queried history.")
        } catch let error as SyntheticOperationError {
            #expect(error.operation == .history)
        }

        let completed = try await store.processSyntheticDelivery(
            .synthetic(snapshot: snapshot) {
                await current.replace(with: [snapshot])
            }
        )

        #expect(completed == snapshot)
        #expect(store.entitlements?.transactions == [snapshot])
        #expect(store.activeEntitlements == [.tier1])
        try await store.close()
    }

    @MainActor
    @Test(
        "delegate decisions reject direct and inherited-child reentrancy",
        arguments: [ReentryMode.direct, .child]
    )
    func decisionReentrancy(mode: ReentryMode) async throws {
        let current = EntitlementValueSource([])
        let fixture = TestSourceFixture(
            currentEntitlements: { await current.read() }
        )
        let holder = TransactionStoreHolder<TestEntitlement>()
        let delegate = ReentrantDecisionDelegate(holder: holder, mode: mode)
        let snapshot = makeSubscriptionSnapshot(
            id: mode == .direct ? 30 : 31,
            productID: .tier1Monthly
        )
        let store = TransactionStore(
            source: fixture.source,
            subscriptionCatalog: testSubscriptionCatalog,
            delegate: delegate
        )
        holder.set(store)
        try await store.waitForInitialReadiness()
        await current.replace(with: [snapshot])

        _ = try await store.process(.verified(makeEnvelope(snapshot: snapshot)))

        #expect(await delegate.sawReentrantError())
        try await store.close()
    }

    @MainActor
    @Test("failure callbacks reject same-store reentrancy")
    func failureCallbackReentrancy() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let holder = TransactionStoreHolder<TestEntitlement>()
        let delegate = ReentrantFailureDelegate(holder: holder)
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
        try await delegate.waitUntilCalled()

        #expect(await delegate.sawReentrantError())
        try await store.close()
    }

    @MainActor
    @Test("dropping an unclosed store cancels physical work before releasing its live lease")
    func unclosedStoreCancellation() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let liveLease = LiveTransactionStoreLease.acquire()
        var store: TransactionStore<TestEntitlement>? = TransactionStore(
            source: fixture.source,
            lifecycle: TransactionStoreLifecycle(liveLease: liveLease),
            subscriptionCatalog: testSubscriptionCatalog
        )
        try await query.waitForRequest(1)
        weak let weakStore = store

        store = nil

        #expect(weakStore == nil)
        try await query.waitForCancellation()
        await liveLease.waitUntilReleased()
        let replacement = LiveTransactionStoreLease.acquire()
        replacement.release()
    }

    #if os(macOS)
        @Test("the live lease is process-wide and releases explicitly")
        func liveLeaseAuthority() async {
            await #expect(processExitsWith: .failure) {
                let first = LiveTransactionStoreLease.acquire()
                let second = LiveTransactionStoreLease.acquire()
                _ = (first, second)
            }

            let first = LiveTransactionStoreLease.acquire()
            first.release()
            let second = LiveTransactionStoreLease.acquire()
            second.release()
        }

        @Test("live-store exclusion crosses TransactionStore generic specializations")
        func crossGenericLiveLease() async {
            await #expect(processExitsWith: .failure) {
                await MainActor.run {
                    let first = TransactionStore(
                        subscriptionCatalog: testSubscriptionCatalog
                    )
                    let second = TransactionStore(
                        subscriptionCatalog: otherSubscriptionCatalog
                    )
                    _ = (first, second)
                }
            }
        }
    #endif
}

private enum OtherEntitlement: Hashable, Sendable {
    case paid
}

private enum OtherPlans: AutoRenewableSubscriptionGroup<OtherEntitlement> {
    static let id = SubscriptionGroupID(rawValue: "other.subscription.group")

    enum ProductID: String, Hashable, Sendable {
        case monthly = "other.subscription.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.monthly, entitlement: .paid)
    }
}

private let otherSubscriptionCatalog =
    AutoRenewableSubscriptionCatalog<OtherEntitlement>(OtherPlans.self)

enum ReentryMode: Sendable {
    case direct
    case child
}

private struct SyntheticOperationError: Error, Sendable {
    let operation: StoreTransactionOperation
}

private struct TransactionDecisionFailure: Error, Sendable {
    let id: UInt64
}

private actor FailingDecisionDelegate: TransactionStoreDelegate {
    private var recorded: [StoreTransactionBackgroundFailure] = []
    private let signal = TestSignal()

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        throw TransactionDecisionFailure(id: transaction.id)
    }

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

private actor FailureRecordingDelegate: TransactionStoreDelegate {
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

private actor StateReadingFailureDelegate: TransactionStoreDelegate {
    private let holder: TransactionStoreHolder<TestEntitlement>
    private let signal = TestSignal()
    private var sawReady = false

    init(holder: TransactionStoreHolder<TestEntitlement>) {
        self.holder = holder
    }

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        sawReady = await MainActor.run {
            guard case .ready = holder.get().entitlementStatus else {
                return false
            }
            return true
        }
        await signal.send()
    }

    func waitForFailure() async throws {
        try await signal.wait(for: 1)
    }

    func observedReadyState() -> Bool {
        sawReady
    }
}

private actor GatedDecisionDelegate: TransactionStoreDelegate {
    private let started = TestSignal()
    private let gate = TestGate()

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        await started.send()
        try await gate.wait()
        return .automatic
    }

    func waitUntilDecisionStarts() async throws {
        try await started.wait(for: 1)
    }

    func allowDecision() async {
        await gate.open()
    }
}

private actor ReentrantDecisionDelegate: TransactionStoreDelegate {
    private let holder: TransactionStoreHolder<TestEntitlement>
    private let mode: ReentryMode
    private var rejected = false

    init(
        holder: TransactionStoreHolder<TestEntitlement>,
        mode: ReentryMode
    ) {
        self.holder = holder
        self.mode = mode
    }

    func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        do {
            switch mode {
            case .direct:
                _ = try await holder.get().refreshEntitlements()
            case .child:
                _ = try await Task { @MainActor in
                    try await holder.get().refreshEntitlements()
                }.value
            }
        } catch StoreTransactionError.reentrantOperation(
            operation: .refreshEntitlements
        ) {
            rejected = true
        }
        return .automatic
    }

    func sawReentrantError() -> Bool {
        rejected
    }
}

private actor ReentrantFailureDelegate: TransactionStoreDelegate {
    private let holder: TransactionStoreHolder<TestEntitlement>
    private let called = TestSignal()
    private var rejected = false

    init(holder: TransactionStoreHolder<TestEntitlement>) {
        self.holder = holder
    }

    func didFail(with failure: StoreTransactionBackgroundFailure) async {
        do {
            _ = try await holder.get().refreshEntitlements()
        } catch StoreTransactionError.reentrantOperation(
            operation: .refreshEntitlements
        ) {
            rejected = true
        } catch {
            Issue.record("Unexpected reentrant failure: \(error)")
        }
        await called.send()
    }

    func waitUntilCalled() async throws {
        try await called.wait(for: 1)
    }

    func sawReentrantError() -> Bool {
        rejected
    }
}
