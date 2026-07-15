import Testing
@testable import StoreTransactionKit

@Suite("Observable Store")
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
        fixture.unfinished.finish()
        let store = Store<SubscriptionID>(
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

    @Test("a later refresh recovers observable state after startup failure")
    func startupFailureRecovery() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        fixture.unfinished.finish()
        let store = Store<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        #expect(store.activeEntitlements == nil)
        await query.waitForRequest(1)
        await query.fail(TestFailure())
        await store.waitForStartup()
        #expect(store.entitlements == nil)
        #expect(store.activeEntitlements == nil)
        #expect(store.startupError != nil)

        let refresh = Task { try await store.refreshEntitlements() }
        await query.waitForRequest(2)
        await query.succeed([
            makeSnapshot(id: 4, productID: SubscriptionID.yearly.rawValue)
        ])
        _ = try await refresh.value

        #expect(store.activeEntitlements == [.yearly])
        #expect(store.startupError == nil)
        try await store.close()
    }

    @Test("an empty set means entitlement resolution completed")
    func emptyTypedEntitlementProjection() async throws {
        let fixture = TestSourceFixture(currentEntitlements: { [] })
        fixture.unfinished.finish()
        let store = Store<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        #expect(store.activeEntitlements == nil)
        await store.waitForStartup()
        #expect(store.activeEntitlements == Set<SubscriptionID>())
        try await store.close()
    }

    @Test("the Store facade rejects handler reentry during startup")
    func startupHandlerReentrancy() async throws {
        let fixture = TestSourceFixture()
        let holder = StoreHolder<SubscriptionID>()
        let rejected = TestSignal()
        let finished = TestSignal()
        fixture.unfinished.yield(
            .verified(
                makeEnvelope(snapshot: makeSnapshot(id: 5)) {
                    await finished.send()
                }))
        fixture.unfinished.finish()

        let store = Store<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in
                do {
                    _ = try await holder.get().refreshEntitlements()
                    Issue.record("Store unexpectedly allowed handler reentry.")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .currentEntitlements
                ) {
                    await rejected.send()
                } catch {
                    Issue.record("Unexpected Store reentrancy error: \(error)")
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
        fixture.unfinished.finish()
        let store = Store<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        await query.waitForRequest(1)

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
            currentEntitlements: { try await query.next() }
        )
        let holder = StoreHolder<SubscriptionID>()
        let closeRejected = TestSignal()
        let startupCompleted = TestSignal()
        fixture.unfinished.yield(
            .verified(makeEnvelope(snapshot: makeSnapshot(id: 6)))
        )
        fixture.unfinished.finish()

        let store = Store<SubscriptionID>(
            source: fixture.source,
            handleTransaction: { _ in
                do {
                    try await holder.get().close()
                    Issue.record("Store unexpectedly allowed a reentrant close.")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .close
                ) {
                    await closeRejected.send()
                } catch {
                    Issue.record("Unexpected Store reentrancy error: \(error)")
                }
            },
            reportFailure: { _ in }
        )
        holder.set(store)
        let startupWaiter = Task {
            await store.waitForStartup()
            await startupCompleted.send()
        }

        await closeRejected.wait(for: 1)
        await query.waitForRequest(1)
        #expect(await startupCompleted.value() == 0)

        await query.succeed([])
        await query.waitForRequest(2)
        await query.succeed([])
        await startupWaiter.value
        #expect(await startupCompleted.value() == 1)
        try await store.close()
    }
}
