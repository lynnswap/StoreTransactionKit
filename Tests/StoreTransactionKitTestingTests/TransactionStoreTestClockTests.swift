import StoreTransactionKitTesting
import Testing

@Suite("TransactionStoreTestClock", .timeLimit(.minutes(1)))
struct TransactionStoreTestClockTests {
    @Test("Instant arithmetic defines the virtual timeline")
    func instantArithmetic() {
        let origin = TransactionStoreTestClock.Instant.zero
        let later = origin.advanced(by: .seconds(3))

        #expect(origin < later)
        #expect(origin.duration(to: later) == .seconds(3))
        #expect(later.duration(to: origin) == .seconds(-3))
    }

    @Test("Initialization selects now and zero resolution")
    func initialization() {
        let initial = TransactionStoreTestClock.Instant.zero
            .advanced(by: .seconds(12))
        let clock = TransactionStoreTestClock(now: initial)

        #expect(clock.now == initial)
        #expect(clock.minimumResolution == .zero)
    }

    @Test("The clock satisfies a Clock Duration dependency")
    func clockDependency() async throws {
        let clock = TransactionStoreTestClock()
        let dependency: any Clock<Duration> = clock
        let sleeper = Task {
            try await dependency.sleep(for: .seconds(2))
        }

        try await clock.waitUntilPendingSleepCount(reaches: 1)
        clock.advance(by: .seconds(2))

        try await sleeper.value
        #expect(clock.now == .zero.advanced(by: .seconds(2)))
    }

    @Test("Advancing releases only due sleepers")
    func releasesOnlyDueSleepers() async throws {
        let clock = TransactionStoreTestClock()
        let first = Task {
            try await clock.sleep(
                until: .zero.advanced(by: .seconds(1)),
                tolerance: nil
            )
        }
        let second = Task {
            try await clock.sleep(
                until: .zero.advanced(by: .seconds(2)),
                tolerance: nil
            )
        }
        let third = Task {
            try await clock.sleep(
                until: .zero.advanced(by: .seconds(3)),
                tolerance: nil
            )
        }

        try await clock.waitUntilPendingSleepCount(reaches: 3)
        clock.advance(by: .seconds(1))
        try await first.value

        third.cancel()
        await #expect(throws: CancellationError.self) {
            try await third.value
        }

        clock.advance(by: .seconds(1))
        try await second.value

        clock.advance(by: .seconds(10))
    }

    @Test("Deadlines at or before now return immediately")
    func elapsedDeadline() async throws {
        let clock = TransactionStoreTestClock()
        clock.advance(by: .seconds(5))

        try await clock.sleep(
            until: .zero.advanced(by: .seconds(5)),
            tolerance: .seconds(1)
        )
        try await clock.sleep(
            until: .zero.advanced(by: .seconds(4)),
            tolerance: nil
        )
    }

    @Test("The registration barrier supports multiple waiters")
    func multipleRegistrationWaiters() async throws {
        let clock = TransactionStoreTestClock()
        let firstWaiter = Task {
            try await clock.waitUntilPendingSleepCount(reaches: 1)
        }
        let secondWaiter = Task {
            try await clock.waitUntilPendingSleepCount(reaches: 2)
        }
        let firstSleeper = Task {
            try await clock.sleep(
                until: .zero.advanced(by: .seconds(1)),
                tolerance: nil
            )
        }

        try await firstWaiter.value

        let secondSleeper = Task {
            try await clock.sleep(
                until: .zero.advanced(by: .seconds(2)),
                tolerance: nil
            )
        }

        try await secondWaiter.value
        clock.advance(by: .seconds(2))
        try await firstSleeper.value
        try await secondSleeper.value
    }

    @Test("Cancelling a sleep removes it and throws CancellationError")
    func cancelledSleep() async throws {
        let clock = TransactionStoreTestClock()
        let sleeper = Task {
            try await clock.sleep(
                until: .zero.advanced(by: .seconds(1)),
                tolerance: nil
            )
        }

        try await clock.waitUntilPendingSleepCount(reaches: 1)
        sleeper.cancel()

        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }

        clock.advance(by: .seconds(1))
    }

    @Test("Cancelling a registration waiter throws CancellationError")
    func cancelledRegistrationWaiter() async {
        let clock = TransactionStoreTestClock()
        let waiter = Task {
            try await clock.waitUntilPendingSleepCount(reaches: 1)
        }

        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }

    @Test("Zero pending sleeps is already reached")
    func zeroPendingSleeps() async throws {
        let clock = TransactionStoreTestClock()
        try await clock.waitUntilPendingSleepCount(reaches: 0)
    }

    @Test("A negative advance is a programmer error")
    func negativeAdvance() async {
        await #expect(processExitsWith: .failure) {
            TransactionStoreTestClock().advance(by: .seconds(-1))
        }
    }

    @Test("A negative pending-sleep target is a programmer error")
    func negativePendingSleepCount() async {
        await #expect(processExitsWith: .failure) {
            try await TransactionStoreTestClock()
                .waitUntilPendingSleepCount(reaches: -1)
        }
    }
}
