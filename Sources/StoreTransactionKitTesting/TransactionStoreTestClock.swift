import Synchronization

/// A manually advanced clock for deterministic tests.
public final class TransactionStoreTestClock: Clock, Sendable {
    public typealias Duration = Swift.Duration

    /// An instant in a ``TransactionStoreTestClock`` timeline.
    public struct Instant: InstantProtocol, Sendable {
        public typealias Duration = Swift.Duration

        /// The origin of a test-clock timeline.
        public static let zero: Instant = Instant(offset: .zero)

        private let offset: Duration

        private init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleepCountWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Instant
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        var sleepCountWaiters: [UInt64: SleepCountWaiter] = [:]

        mutating func takeID() -> UInt64 {
            precondition(nextID < .max, "The test clock exhausted its waiter identifiers.")
            defer { nextID += 1 }
            return nextID
        }

        mutating func takeSatisfiedSleepCountWaiters() -> [CheckedContinuation<Void, any Error>] {
            let readyIDs = sleepCountWaiters.compactMap { id, waiter in
                waiter.target <= sleepers.count ? id : nil
            }
            return readyIDs.compactMap { id in
                sleepCountWaiters.removeValue(forKey: id)?.continuation
            }
        }
    }

    private enum SleepRegistration {
        case pending([CheckedContinuation<Void, any Error>])
        case elapsed
        case cancelled
    }

    private enum SleepCountWaiterRegistration {
        case pending
        case reached
        case cancelled
    }

    private let state: Mutex<State>

    /// The clock's current virtual instant.
    public var now: Instant {
        state.withLock { $0.now }
    }

    /// The clock's virtual-time resolution.
    public var minimumResolution: Duration {
        .zero
    }

    /// Creates a clock at the supplied virtual instant.
    public init(now: Instant = .zero) {
        state = Mutex(State(now: now))
    }

    /// Suspends until the deadline is reached by a call to ``advance(by:)``.
    ///
    /// The clock resumes at the exact deadline boundary, so `tolerance` does
    /// not alter virtual-time scheduling.
    public func sleep(
        until deadline: Instant,
        tolerance: Duration?
    ) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.takeID() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registration = state.withLock { state -> SleepRegistration in
                    guard !Task.isCancelled else { return .cancelled }
                    guard deadline > state.now else { return .elapsed }

                    state.sleepers[id] = Sleeper(
                        id: id,
                        deadline: deadline,
                        continuation: continuation
                    )
                    return .pending(state.takeSatisfiedSleepCountWaiters())
                }

                switch registration {
                case .pending(let waiters):
                    for waiter in waiters {
                        waiter.resume()
                    }
                case .elapsed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelSleeper(id)
        }
    }

    /// Advances virtual time and resumes every sleeper whose deadline is due.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "A test clock cannot advance by a negative duration.")

        let continuations = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = state.now.advanced(by: duration)
            let dueIDs = state.sleepers.values
                .filter { $0.deadline <= state.now }
                .sorted {
                    if $0.deadline != $1.deadline {
                        return $0.deadline < $1.deadline
                    }
                    return $0.id < $1.id
                }
                .map(\.id)
            return dueIDs.compactMap { id in
                state.sleepers.removeValue(forKey: id)?.continuation
            }
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Suspends until at least `count` sleeps are registered with the clock.
    public func waitUntilPendingSleepCount(
        reaches count: Int
    ) async throws {
        precondition(count >= 0, "A pending sleep count cannot be negative.")
        try Task.checkCancellation()
        let id = state.withLock { $0.takeID() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registration = state.withLock { state -> SleepCountWaiterRegistration in
                    guard !Task.isCancelled else { return .cancelled }
                    guard state.sleepers.count < count else { return .reached }
                    state.sleepCountWaiters[id] = SleepCountWaiter(
                        target: count,
                        continuation: continuation
                    )
                    return .pending
                }

                switch registration {
                case .pending:
                    break
                case .reached:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelSleepCountWaiter(id)
        }
    }

    private func cancelSleeper(_ id: UInt64) {
        let continuation = state.withLock { state in
            state.sleepers.removeValue(forKey: id)?.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelSleepCountWaiter(_ id: UInt64) {
        let continuation = state.withLock { state in
            state.sleepCountWaiters.removeValue(forKey: id)?.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
