import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Failure reporter dispatcher", .timeLimit(.minutes(1)))
struct FailureReporterDispatcherTests {
    @Test("capacity one delivers every admitted failure before enqueue returns")
    func boundedDeliveryIsLossless() async throws {
        let callbackEntered = TestSignal()
        let callbackGate = TestGate()
        let callbackValues = UInt64Recorder()
        let enqueueCompleted = TestSignal()
        let dispatcher = FailureReporterDispatcher(capacity: 1) { failure in
            guard let transactionID = failure.transactionID else {
                Issue.record("The test failure lost its transaction identifier.")
                return
            }
            await callbackValues.append(transactionID)
            await callbackEntered.send()
            _ = try? await callbackGate.wait()
        }

        let first = Task {
            await dispatcher.enqueue(makeFailure(id: 1))
            await enqueueCompleted.send()
        }
        try await callbackEntered.wait(for: 1)
        #expect(await enqueueCompleted.value() == 0)

        let second = Task {
            await dispatcher.enqueue(makeFailure(id: 2))
            await enqueueCompleted.send()
        }
        let third = Task {
            await dispatcher.enqueue(makeFailure(id: 3))
            await enqueueCompleted.send()
        }

        await callbackGate.open()
        await first.value
        await second.value
        await third.value
        await dispatcher.sealAndDrain()

        let values = await callbackValues.snapshot()
        #expect(values.first == 1)
        #expect(Set(values) == [1, 2, 3])
        #expect(await enqueueCompleted.value() == 3)
    }

    @Test("seal waits for an active failure callback and its enqueue receipt")
    func sealDrainsActiveCallback() async throws {
        let callbackEntered = TestSignal()
        let callbackGate = TestGate()
        let enqueueCompleted = TestSignal()
        let sealStarted = TestSignal()
        let sealCompleted = TestSignal()
        let dispatcher = FailureReporterDispatcher(capacity: 1) { _ in
            await callbackEntered.send()
            _ = try? await callbackGate.wait()
        }

        let enqueue = Task {
            await dispatcher.enqueue(makeFailure(id: 1))
            await enqueueCompleted.send()
        }
        try await callbackEntered.wait(for: 1)

        let seal = Task {
            await sealStarted.send()
            await dispatcher.sealAndDrain()
            await sealCompleted.send()
        }
        try await sealStarted.wait(for: 1)
        #expect(await enqueueCompleted.value() == 0)
        #expect(await sealCompleted.value() == 0)

        await callbackGate.open()
        await enqueue.value
        await seal.value

        #expect(await enqueueCompleted.value() == 1)
        #expect(await sealCompleted.value() == 1)
    }

    private func makeFailure(id: UInt64) -> StoreTransactionBackgroundFailure {
        StoreTransactionBackgroundFailure(
            source: .updates,
            transactionID: id,
            productID: "product-\(id)",
            underlyingError: TestFailure()
        )
    }
}

@Suite("Restore coordinator failures", .timeLimit(.minutes(1)))
struct RestoreCoordinatorFailureTests {
    @Test("coalesced waiters share a failure and the next reservation retries")
    func coalescedFailureAllowsRetry() async throws {
        let synchronization = ControlledRestoreSynchronization()
        let entitlementQueryCount = TestSignal()
        let entitlements = EntitlementRefreshCoordinator(
            query: { _ in
                await entitlementQueryCount.send()
                return []
            },
            didChange: { _ in }
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

        await synchronization.releaseFirstAttempt()
        await #expect(throws: RestoreCoordinatorFailure.self) {
            _ = try await first.receipt.terminalValue()
        }
        await #expect(throws: RestoreCoordinatorFailure.self) {
            _ = try await second.receipt.terminalValue()
        }

        let retry = await coordinator.reserve()
        #expect(retry.role == .owner)
        #expect(retry.receipt !== first.receipt)
        try await synchronization.waitForAttempt(2)
        let value = try await retry.receipt.terminalValue()

        #expect(value.transactions.isEmpty)
        #expect(await synchronization.attemptCount() == 2)
        #expect(await entitlementQueryCount.value() == 1)
        await entitlements.sealAndDrain()
    }
}

@Suite("Session closing admission", .timeLimit(.minutes(1)))
struct SessionClosingAdmissionTests {
    @Test("closing rejects every new session operation")
    func closingRejectsNewOperations() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        let startup = Task { try await session.start() }
        try await query.waitForRequest(1)
        await query.succeed([])
        _ = try await startup.value

        let acceptedRefresh = Task {
            try await session.currentEntitlements()
        }
        try await query.waitForRequest(2)

        let close = Task { try await session.close() }
        try await fixture.updateTermination.wait(for: 1)

        await expectClosing("start") {
            _ = try await session.start()
        }
        await expectClosing("process") {
            _ = try await session.process(.pending)
        }
        await expectClosing("currentEntitlements") {
            _ = try await session.currentEntitlements()
        }
        await expectClosing("history") {
            _ = try await session.history(for: "product")
        }
        await expectClosing("restorePurchases") {
            _ = try await session.restorePurchases()
        }

        await query.succeed([])
        _ = try await acceptedRefresh.value
        try await close.value
    }

    private func expectClosing(
        _ operationName: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("\(operationName) accepted new work while closing.")
        } catch StoreTransactionError.closing {
        } catch {
            Issue.record("\(operationName) returned an unexpected error: \(error)")
        }
    }
}

private actor ControlledRestoreSynchronization {
    private let started = TestSignal()
    private let firstAttemptGate = TestGate()
    private var attempts = 0

    func run() async throws {
        attempts += 1
        let attempt = attempts
        await started.send()
        if attempt == 1 {
            try await firstAttemptGate.wait()
            throw TestFailure()
        }
    }

    func waitForAttempt(_ count: Int) async throws {
        try await started.wait(for: count)
    }

    func releaseFirstAttempt() async {
        await firstAttemptGate.open()
    }

    func attemptCount() -> Int {
        attempts
    }
}
