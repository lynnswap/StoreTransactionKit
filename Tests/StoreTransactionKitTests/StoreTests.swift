import Testing
@testable import StoreTransactionKit

@Suite("Observable TransactionStore", .timeLimit(.minutes(1)))
@MainActor
struct StoreTests {
    private enum SubscriptionID: String, Hashable, Sendable {
        case monthly = "subscription.monthly"
        case yearly = "subscription.yearly"
    }

    @Test("app-defined identifiers project current entitlements")
    func typedEntitlementProjection() async throws {
        let values = EntitlementValueSource([
            makeSnapshot(id: 1, productID: SubscriptionID.monthly.rawValue),
            makeSnapshot(id: 2, productID: "nonconsumable.outside-enum"),
        ])
        let fixture = TestSourceFixture(
            currentEntitlements: { await values.read() }
        )
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        #expect(store.activeEntitlements == nil)
        await store.waitForStartup()

        #expect(store.activeEntitlements == [.monthly])
        #expect(
            store.entitlements?.transactions.map(\.productID) == [
                "nonconsumable.outside-enum",
                SubscriptionID.monthly.rawValue,
            ])

        await values.replace(with: [
            makeSnapshot(id: 3, productID: SubscriptionID.yearly.rawValue)
        ])
        _ = try await store.refreshEntitlements()

        #expect(store.activeEntitlements == [.yearly])
        #expect(store.startupError == nil)
        try await store.close()
    }

    @Test("an upgraded transaction remains in the snapshot without granting access")
    func upgradedTransactionProjection() async throws {
        let fixture = TestSourceFixture(
            currentEntitlements: {
                [
                    makeSnapshot(
                        id: 1,
                        productID: SubscriptionID.monthly.rawValue,
                        isUpgraded: true
                    ),
                    makeSnapshot(
                        id: 2,
                        productID: SubscriptionID.yearly.rawValue
                    ),
                ]
            }
        )
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        await store.waitForStartup()

        #expect(store.activeEntitlements == [.yearly])
        #expect(
            store.entitlements?.transactions.map(\.productID) == [
                SubscriptionID.monthly.rawValue,
                SubscriptionID.yearly.rawValue,
            ]
        )
        try await store.close()
    }

    @Test("a later refresh recovers observable state after startup failure")
    func startupFailureRecovery() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        #expect(store.activeEntitlements == nil)
        try await query.waitForRequest(1)
        await query.fail(TestFailure())
        await store.waitForStartup()
        #expect(store.entitlements == nil)
        #expect(store.activeEntitlements == nil)
        #expect(store.startupError != nil)

        let refresh = Task { try await store.refreshEntitlements() }
        try await query.waitForRequest(2)
        await query.succeed([
            makeSnapshot(id: 4, productID: SubscriptionID.yearly.rawValue)
        ])
        _ = try await refresh.value

        #expect(store.activeEntitlements == [.yearly])
        #expect(store.startupError == nil)
        try await store.close()
    }

    @Test("startup exposes the underlying unfinished handler failure")
    func startupUnwrapsReportedHandlerFailure() async throws {
        let snapshot = makeSnapshot(
            id: 8,
            productID: "consumable.startup",
            productType: .consumable
        )
        let fixture = TestSourceFixture(
            queryUnfinished: {
                [.verified(makeEnvelope(snapshot: snapshot))]
            }
        )
        let handlerCalls = TestSignal()
        let reports = StringRecorder()
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
                if await handlerCalls.value() == 1 {
                    throw TestFailure()
                }
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-8")
                } else {
                    await reports.append("unexpected")
                }
            }
        )

        await store.waitForStartup()

        #expect(store.startupError is TestFailure)
        #expect(store.entitlements == nil)
        #expect(await handlerCalls.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-8"])

        let entitlements = try await store.refreshEntitlements()

        #expect(entitlements.transactions.isEmpty)
        #expect(store.startupError == nil)
        #expect(await handlerCalls.value() == 2)
        #expect(await reports.snapshot() == ["unfinished-8"])
        try await store.close()
    }

    @Test("a background refresh failure preserves resolved entitlement state")
    func backgroundFailurePreservesResolvedEntitlements() async throws {
        let snapshot = makeSnapshot(
            id: 7,
            productID: SubscriptionID.monthly.rawValue
        )
        let query = ControlledEntitlementQuery()
        let reports = StringRecorder()
        let reported = TestSignal()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { failure in
                if failure.source == .entitlementRefresh,
                    failure.transactionID == snapshot.id,
                    failure.productID == snapshot.productID,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("entitlement-refresh-7")
                } else {
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )

        try await query.waitForRequest(1)
        await query.succeed([snapshot])
        await store.waitForStartup()

        fixture.updates.yield(
            .verified(makeEnvelope(snapshot: snapshot))
        )
        try await query.waitForRequest(2)
        await query.fail(TestFailure())
        try await reported.wait(for: 1)

        #expect(store.activeEntitlements == [.monthly])
        #expect(store.startupError == nil)
        #expect(await reports.snapshot() == ["entitlement-refresh-7"])
        try await store.close()
    }

    @Test("a dependency cancellation failure remains a startup error")
    func startupCancellationFailure() async throws {
        let fixture = TestSourceFixture(
            currentEntitlements: { throw CancellationError() }
        )
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        await store.waitForStartup()

        #expect(store.startupError is CancellationError)
        #expect(store.activeEntitlements == nil)
        try await store.close()
    }

    @Test("an empty set means entitlement resolution completed")
    func emptyTypedEntitlementProjection() async throws {
        let fixture = TestSourceFixture(currentEntitlements: { [] })
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        #expect(store.activeEntitlements == nil)
        await store.waitForStartup()
        #expect(store.activeEntitlements == Set<SubscriptionID>())
        try await store.close()
    }

    @Test("the TransactionStore facade rejects handler reentry during startup")
    func startupHandlerReentrancy() async throws {
        let holder = TransactionStoreHolder<SubscriptionID>()
        let rejected = TestSignal()
        let finished = TestSignal()
        let fixture = TestSourceFixture(
            queryUnfinished: {
                [
                    .verified(
                        makeEnvelope(snapshot: makeSnapshot(id: 5)) {
                            await finished.send()
                        })
                ]
            }
        )

        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in
                do {
                    _ = try await holder.get().refreshEntitlements()
                    Issue.record("TransactionStore unexpectedly allowed handler reentry.")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .currentEntitlements
                ) {
                    await rejected.send()
                } catch {
                    Issue.record("Unexpected TransactionStore reentrancy error: \(error)")
                }
            },
            reportFailure: { _ in }
        )
        holder.set(store)

        await store.waitForStartup()

        #expect(await rejected.value() == 1)
        #expect(await finished.value() == 1)
        try await store.close()
    }

    @Test("a cancelled caller stops waiting without cancelling startup")
    func startupWaitCancellation() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        try await query.waitForRequest(1)

        let refresh = Task { try await store.refreshEntitlements() }
        refresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await refresh.value
        }
        #expect(await fixture.entitlementQueryCount.value() == 1)

        await query.succeed([])
        await store.waitForStartup()
        try await store.close()
    }

    @Test("a rejected reentrant close does not cancel startup")
    func reentrantClosePreservesStartup() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() },
            queryUnfinished: {
                [.verified(makeEnvelope(snapshot: makeSnapshot(id: 6)))]
            }
        )
        let holder = TransactionStoreHolder<SubscriptionID>()
        let closeRejected = TestSignal()
        let startupCompleted = TestSignal()

        let store = TransactionStore<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in
                do {
                    try await holder.get().close()
                    Issue.record("TransactionStore unexpectedly allowed a reentrant close.")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .close
                ) {
                    await closeRejected.send()
                } catch {
                    Issue.record("Unexpected TransactionStore reentrancy error: \(error)")
                }
            },
            reportFailure: { _ in }
        )
        holder.set(store)
        let startupWaiter = Task {
            await store.waitForStartup()
            await startupCompleted.send()
        }

        try await query.waitForRequest(1)
        #expect(await startupCompleted.value() == 0)

        await query.succeed([])
        try await closeRejected.wait(for: 1)
        try await query.waitForRequest(2)
        #expect(await startupCompleted.value() == 0)
        await query.succeed([])
        await startupWaiter.value
        #expect(await startupCompleted.value() == 1)
        try await store.close()
    }
}
