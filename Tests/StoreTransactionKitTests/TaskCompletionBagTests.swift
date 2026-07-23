import Testing
@testable import StoreTransactionKit

@Suite("Task completion bag", .timeLimit(.minutes(1)))
struct TaskCompletionBagTests {
    @Test("completed tasks are released without waiting for shutdown")
    func completedTasksAreReleased() async throws {
        let bag = TaskCompletionBag()
        let gate = TestGate()
        let completed = TestSignal()

        for _ in 0..<32 {
            let registration = bag.reserve()
            let task = Task {
                try? await gate.wait()
                registration.complete()
                await completed.send()
            }
            registration.attach(task)
        }

        #expect(bag.retainedTaskCount() == 32)
        await gate.open()
        try await completed.wait(for: 32)
        #expect(bag.retainedTaskCount() == 0)
    }

    @Test("completion before attachment does not retain the task")
    func completionBeforeAttachment() async throws {
        let bag = TaskCompletionBag()
        let completed = TestSignal()
        let registration = bag.reserve()
        let task = Task {
            registration.complete()
            await completed.send()
        }

        try await completed.wait(for: 1)
        registration.attach(task)

        #expect(bag.retainedTaskCount() == 0)
    }

    @Test("cancellation before attachment reaches the task")
    func cancellationBeforeAttachment() async throws {
        let bag = TaskCompletionBag()
        let gate = TestGate()
        let cancelled = TestSignal()
        let registration = bag.reserve()

        bag.cancel()
        let task = Task {
            defer { registration.complete() }
            do {
                try await gate.wait()
            } catch is CancellationError {
                await cancelled.send()
            } catch {
                Issue.record("Unexpected task failure: \(error)")
            }
        }
        registration.attach(task)

        try await cancelled.wait(for: 1)
        await bag.waitForAll()
        #expect(bag.retainedTaskCount() == 0)
    }
}
