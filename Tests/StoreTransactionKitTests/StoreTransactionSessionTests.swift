import Foundation
import Testing
@testable import StoreTransactionKit

@Suite("StoreTransactionSession")
struct StoreTransactionSessionTests {
    @Test("start publishes initial entitlements and close terminates producers")
    func startAndClose() async throws {
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let publicationSizes = UInt64Recorder()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            },
            reportFailure: { _ in }
        )

        let readiness = try await session.start()
        #expect(readiness.entitlements.transactions.isEmpty)
        #expect(await publicationSizes.snapshot() == [0])

        try await session.close()
        await fixture.updateTermination.wait(for: 1)
    }

    @Test("updates use the durable handler then finish and refresh")
    func updateProcessing() async throws {
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let events = StringRecorder()
        let finished = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { snapshot in
                await events.append("handle-\(snapshot.id)")
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                Issue.record("Unexpected background failure: \(failure)")
            }
        )
        _ = try await session.start()

        let snapshot = makeSnapshot(id: 10)
        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: snapshot) {
                    await events.append("finish-10")
                    await finished.send()
                }))
        await finished.wait(for: 1)

        #expect(await events.snapshot() == ["handle-10", "finish-10"])
        await fixture.entitlementQueryCount.wait(for: 2)
        try await session.close()
    }

    @Test("background handler failures are reported and never finished")
    func backgroundFailure() async throws {
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let reported = TestSignal()
        let finished = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in throw TestFailure() },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                if failure.transactionID == 11 {
                    await reported.send()
                }
            }
        )
        _ = try await session.start()
        fixture.updates.yield(
            .verified(
                makeEnvelope(
                    snapshot: makeSnapshot(id: 11)
                ) {
                    await finished.send()
                }))

        await reported.wait(for: 1)
        #expect(await finished.value() == 0)
        try await session.close()
    }

    @Test("close before start is idempotent and later operations are rejected")
    func closeBeforeStart() async throws {
        let fixture = TestSourceFixture()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        try await session.close()
        try await session.close()
        await #expect(throws: StoreTransactionError.self) {
            _ = try await session.start()
        }
    }

    @Test("callbacks reject reentry into their own session")
    func callbackReentrancy() async throws {
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let holder = SessionHolder()
        let observations = StringRecorder()
        let finished = TestSignal()
        let failureReported = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                do {
                    try await holder.get().close()
                    await observations.append("handler-unexpected-success")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .close
                ) {
                    await observations.append("handler-rejected")
                } catch {
                    Issue.record("Unexpected handler reentrancy error: \(error)")
                }
            },
            entitlementsDidChange: { _ in
                do {
                    _ = try await holder.get().currentEntitlements()
                    await observations.append("entitlements-unexpected-success")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .currentEntitlements
                ) {
                    await observations.append("entitlements-rejected")
                } catch {
                    Issue.record("Unexpected entitlement reentrancy error: \(error)")
                }
            },
            reportFailure: { _ in
                do {
                    _ = try await holder.get().history(for: "product")
                    await observations.append("reporter-unexpected-success")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .history
                ) {
                    await observations.append("reporter-rejected")
                } catch {
                    Issue.record("Unexpected reporter reentrancy error: \(error)")
                }
                await failureReported.send()
            }
        )
        holder.set(session)

        _ = try await session.start()
        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: makeSnapshot(id: 12)) {
                    await finished.send()
                }))
        await finished.wait(for: 1)
        fixture.updates.yield(.unverified(TestFailure()))
        await failureReported.wait(for: 1)

        #expect(
            await observations.snapshot() == [
                "entitlements-rejected",
                "handler-rejected",
                "reporter-rejected",
            ])
        try await session.close()
    }

    @Test("a callback may operate on a different session")
    func callbackMayUseAnotherSession() async throws {
        let otherFixture = TestSourceFixture()
        let otherSession = StoreTransactionSession(
            source: otherFixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        let fixture = TestSourceFixture()
        fixture.unfinished.finish()
        let callbackCompleted = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in
                do {
                    try await otherSession.close()
                    await callbackCompleted.send()
                } catch {
                    Issue.record("A different session rejected the callback: \(error)")
                }
            },
            reportFailure: { _ in }
        )

        _ = try await session.start()
        await callbackCompleted.wait(for: 1)
        try await session.close()
    }
}
