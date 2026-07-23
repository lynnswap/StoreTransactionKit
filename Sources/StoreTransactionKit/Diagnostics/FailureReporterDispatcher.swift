import Foundation
import OSLog

package actor FailureReporterDispatcher {
    private struct Item: Sendable {
        let failure: StoreTransactionBackgroundFailure
        let receipt: ProcessingReceipt<Void>
    }

    private let sessionID: UUID
    private let lifetime: TransactionStoreLifecycle?
    private let capacity: Int
    private let report: (@Sendable (StoreTransactionBackgroundFailure) async -> Void)?
    private var queue: [Item] = []
    private var spaceWaiters: [ProcessingReceipt<Void>] = []
    private var worker: Task<Void, Never>?
    private var acceptsFailures = true
    private nonisolated let workerCancellation = TaskCancellationBag()

    package init(
        sessionID: UUID = UUID(),
        capacity: Int = 32,
        lifetime: TransactionStoreLifecycle? = nil,
        report:
            (@Sendable (StoreTransactionBackgroundFailure) async -> Void)? = nil
    ) {
        precondition(capacity > 0)
        self.sessionID = sessionID
        self.lifetime = lifetime
        self.capacity = capacity
        self.report = report
    }

    package func enqueue(_ failure: StoreTransactionBackgroundFailure) async {
        precondition(acceptsFailures)
        while queue.count >= capacity {
            let space = ProcessingReceipt<Void>()
            spaceWaiters.append(space)
            _ = try? await space.terminalValue()
            precondition(acceptsFailures)
        }
        let receipt = ProcessingReceipt<Void>()
        queue.append(Item(failure: failure, receipt: receipt))
        startWorkerIfNeeded()
        _ = try? await receipt.terminalValue()
    }

    package func sealAndDrain() async {
        acceptsFailures = false
        let activeWorker = worker
        await activeWorker?.value
        precondition(queue.isEmpty)
        precondition(spaceWaiters.isEmpty)
    }

    package nonisolated func cancelSynchronously() {
        workerCancellation.cancel()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.drainQueue()
        }
        worker = task
        workerCancellation.insert(task)
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if !spaceWaiters.isEmpty {
                spaceWaiters.removeFirst().succeed(())
            }
            await StoreTransactionCallbackContext.$current.withValue(
                StoreTransactionCallbackInvocation(
                    sessionID: sessionID,
                    callback: .failureReporter
                )
            ) {
                let errorType = String(
                    reflecting: type(of: item.failure.underlyingError)
                )
                Self.logger.error(
                    "Background StoreKit failure from \(String(describing: item.failure.source), privacy: .public) [\(errorType, privacy: .public)]"
                )
                if let report {
                    await report(item.failure)
                }
            }
            item.receipt.succeed(())
        }
        worker = nil
        workerCancellation.removeAll()
    }

    isolated deinit {
        worker?.cancel()
    }

    private nonisolated static let logger = Logger(
        subsystem: "StoreTransactionKit",
        category: "TransactionStore"
    )
}
