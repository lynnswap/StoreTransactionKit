import Foundation
import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Runtime contracts")
struct RuntimeContractTests {
    @Test("immediate purchase outcomes honor caller cancellation")
    func immediatePurchaseOutcomeCancellation() async throws {
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        _ = try await session.start()

        for result: Product.PurchaseResult in [.pending, .userCancelled] {
            let gate = TestGate()
            let process = Task {
                await gate.wait()
                return try await session.process(result)
            }
            process.cancel()
            await gate.open()

            await #expect(throws: CancellationError.self) {
                _ = try await process.value
            }
        }

        try await session.close()
    }

    @Test("concurrent restore callers share one synchronization")
    func restoreCoalescing() async throws {
        let synchronizationStarted = TestSignal()
        let synchronizationGate = TestGate()
        let fixture = TestSourceFixture(
            synchronize: {
                await synchronizationStarted.send()
                await synchronizationGate.wait()
            }
        )
        fixture.unfinished.finish()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        _ = try await session.start()

        async let first = session.restorePurchases()
        await synchronizationStarted.wait(for: 1)
        async let second = session.restorePurchases()
        await Task.yield()
        #expect(await synchronizationStarted.value() == 1)

        await synchronizationGate.open()
        let (firstValue, secondValue) = try await (first, second)

        #expect(firstValue == secondValue)
        #expect(await synchronizationStarted.value() == 1)
        #expect(await fixture.entitlementQueryCount.value() == 2)
        try await session.close()
    }

    @Test("an abandoned refresh reports its later failure exactly once")
    func abandonedRefreshFailure() async throws {
        let query = ControlledEntitlementQuery()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        fixture.unfinished.finish()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { failure in
                switch failure.source {
                case .abandonedDirectOperation(.currentEntitlements):
                    await reports.append("abandoned-refresh")
                default:
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )

        let startup = Task { try await session.start() }
        await query.waitForRequest(1)
        await query.succeed([])
        _ = try await startup.value

        let refresh = Task { try await session.currentEntitlements() }
        await query.waitForRequest(2)
        refresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await refresh.value
        }
        await query.fail(TestFailure())
        await reported.wait(for: 1)

        try await session.close()
        #expect(await reports.snapshot() == ["abandoned-refresh"])
    }

    @Test("history is newest first and retains revoked transactions")
    func historyOrderAndMembership() async throws {
        let sharedDate = Date(timeIntervalSince1970: 100)
        let older = makeSnapshot(id: 1, purchaseDate: Date(timeIntervalSince1970: 10))
        let lowerID = makeSnapshot(
            id: 2,
            purchaseDate: sharedDate,
            signedDate: Date(timeIntervalSince1970: 200)
        )
        let higherIDRevoked = makeSnapshot(
            id: 3,
            purchaseDate: sharedDate,
            signedDate: Date(timeIntervalSince1970: 200),
            revocationDate: Date(timeIntervalSince1970: 300)
        )
        let newestSigned = makeSnapshot(
            id: 4,
            purchaseDate: sharedDate,
            signedDate: Date(timeIntervalSince1970: 201)
        )
        let fixture = TestSourceFixture(
            history: { _ in
                [older, lowerID, higherIDRevoked, newestSigned]
            }
        )
        fixture.unfinished.finish()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        _ = try await session.start()

        let history = try await session.history(for: "product")

        #expect(history.map(\.id) == [4, 3, 2, 1])
        #expect(history[1].revocationDate != nil)
        try await session.close()
    }

    @Test("background entitlement refresh failures have their own source")
    func backgroundEntitlementRefreshFailure() async throws {
        let query = ControlledEntitlementQuery()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        fixture.unfinished.finish()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { failure in
                await reports.append(
                    "\(failure.source)-\(failure.transactionID ?? 0)-\(failure.productID ?? "")"
                )
                await reported.send()
            }
        )

        let startup = Task { try await session.start() }
        await query.waitForRequest(1)
        await query.succeed([])
        _ = try await startup.value

        fixture.updates.yield(
            .verified(makeEnvelope(snapshot: makeSnapshot(id: 19)))
        )
        await query.waitForRequest(2)
        await query.fail(TestFailure())
        await reported.wait(for: 1)

        try await session.close()
        #expect(await reports.snapshot() == ["entitlementRefresh-19-product"])
    }

    @Test("close completes after accepted handling and finish")
    func closeDrainsAcceptedTransaction() async throws {
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let events = StringRecorder()
        let closeCallersStarted = TestSignal()
        let closeCallersFinished = TestSignal()
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await events.append("handle-start")
                await handlerStarted.send()
                await handlerGate.wait()
                await events.append("handle-end")
            },
            reportFailure: { _ in }
        )
        _ = try await session.start()
        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: makeSnapshot(id: 20)) {
                    await events.append("finish")
                }))
        await handlerStarted.wait(for: 1)

        let firstClose = Task {
            await closeCallersStarted.send()
            try await session.close()
            await events.append("close-1")
            await closeCallersFinished.send()
        }
        let secondClose = Task {
            await closeCallersStarted.send()
            try await session.close()
            await events.append("close-2")
            await closeCallersFinished.send()
        }
        await closeCallersStarted.wait(for: 2)
        #expect(await closeCallersFinished.value() == 0)

        await handlerGate.open()
        try await firstClose.value
        try await secondClose.value

        let recorded = await events.snapshot()
        #expect(recorded.prefix(3) == ["handle-start", "handle-end", "finish"])
        #expect(Set(recorded.suffix(2)) == ["close-1", "close-2"])
    }
}

@Suite("Completed revision cache")
struct CompletedRevisionCacheTests {
    @Test("eviction removes the oldest completed revision")
    func eviction() {
        var cache = CompletedRevisionCache(capacity: 2)
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)

        cache.insert(first)
        cache.insert(second)
        cache.insert(third)

        #expect(!cache.contains(first))
        #expect(cache.contains(second))
        #expect(cache.contains(third))
    }
}

@Suite("Task completion bag")
struct TaskCompletionBagTests {
    @Test("completed tasks are released before shutdown")
    func completedTasksAreReleased() async {
        let bag = TaskCompletionBag()
        let completed = TestSignal()

        for _ in 0..<32 {
            bag.insert(
                Task {
                    await completed.send()
                })
        }
        await completed.wait(for: 32)

        for _ in 0..<100 where bag.retainedTaskCount() != 0 {
            await Task.yield()
        }
        #expect(bag.retainedTaskCount() == 0)
    }
}
