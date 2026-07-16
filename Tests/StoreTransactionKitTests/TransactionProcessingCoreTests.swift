import Foundation
import Testing
@testable import StoreTransactionKit

@Suite("TransactionProcessingCore", .timeLimit(.minutes(1)))
struct TransactionProcessingCoreTests {
    @Test("durable handling precedes finish")
    func handlerPrecedesFinish() async throws {
        let events = StringRecorder()
        let gate = TestGate()
        let handlerStarted = TestSignal()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await events.append("handle-start")
            await handlerStarted.send()
            try await gate.wait()
            await events.append("handle-end")
        }
        let snapshot = makeSnapshot(id: 1)
        let receipt = await core.accept(
            makeEnvelope(snapshot: snapshot) {
                await events.append("finish")
            }
        ).receipt

        try await handlerStarted.wait(for: 1)
        #expect(await events.snapshot() == ["handle-start"])
        await gate.open()
        _ = try await receipt.terminalValue()
        #expect(
            await events.snapshot() == [
                "handle-start", "handle-end", "finish",
            ])
        await core.finishInputAndDrain()
    }

    @Test("handler failure leaves the revision retryable and unfinished")
    func failedHandlerIsRetryable() async throws {
        let attempts = TestSignal()
        let finishes = TestSignal()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await attempts.send()
            if await attempts.value() == 1 {
                throw TestFailure()
            }
        }
        let snapshot = makeSnapshot(id: 2)
        let envelope = makeEnvelope(snapshot: snapshot) {
            await finishes.send()
        }

        let first = await core.accept(envelope)
        await #expect(throws: TestFailure.self) {
            _ = try await first.receipt.terminalValue()
        }
        #expect(await finishes.value() == 0)

        let second = await core.accept(envelope)
        _ = try await second.receipt.terminalValue()
        #expect(first.role == .owner)
        #expect(second.role == .owner)
        #expect(await attempts.value() == 2)
        #expect(await finishes.value() == 1)
        await core.finishInputAndDrain()
    }

    @Test("equal revisions join in flight and completed revisions are suppressed")
    func equalRevisionCoalescing() async throws {
        let handlerGate = TestGate()
        let handlerStarted = TestSignal()
        let handles = TestSignal()
        let firstFinish = TestSignal()
        let duplicateFinish = TestSignal()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handles.send()
            await handlerStarted.send()
            try await handlerGate.wait()
        }
        let snapshot = makeSnapshot(id: 3)
        let first = await core.accept(
            makeEnvelope(
                snapshot: snapshot,
                revision: "same"
            ) {
                await firstFinish.send()
            })
        try await handlerStarted.wait(for: 1)
        let duplicate = await core.accept(
            makeEnvelope(
                snapshot: snapshot,
                revision: "same"
            ) {
                await duplicateFinish.send()
            })

        await handlerGate.open()
        _ = try await first.receipt.terminalValue()
        _ = try await duplicate.receipt.terminalValue()
        let completed = await core.accept(
            makeEnvelope(
                snapshot: snapshot,
                revision: "same"
            ) {
                await duplicateFinish.send()
            })
        _ = try await completed.receipt.terminalValue()

        #expect(first.role == .owner)
        #expect(duplicate.role == .inFlightObserver)
        #expect(completed.role == .completedObserver)
        #expect(await handles.value() == 1)
        #expect(await firstFinish.value() == 1)
        #expect(await duplicateFinish.value() == 0)
        await core.finishInputAndDrain()
    }

    @Test("the explicit worker keeps FIFO order across suspension")
    func fifoOrder() async throws {
        let events = StringRecorder()
        let firstGate = TestGate()
        let firstStarted = TestSignal()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { snapshot in
            await events.append("handle-\(snapshot.id)")
            if snapshot.id == 1 {
                await firstStarted.send()
                try await firstGate.wait()
            }
        }
        let first = await core.accept(
            makeEnvelope(snapshot: makeSnapshot(id: 1)) {
                await events.append("finish-1")
            })
        try await firstStarted.wait(for: 1)
        let second = await core.accept(
            makeEnvelope(snapshot: makeSnapshot(id: 2)) {
                await events.append("finish-2")
            })

        await firstGate.open()
        _ = try await first.receipt.terminalValue()
        _ = try await second.receipt.terminalValue()
        #expect(
            await events.snapshot() == [
                "handle-1", "finish-1", "handle-2", "finish-2",
            ])
        await core.finishInputAndDrain()
    }
}
