import Foundation

package actor FailureReporterDispatcher {
    private struct Item: Sendable {
        let failure: StoreTransactionBackgroundFailure
        let receipt: ProcessingReceipt<Void>
    }

    private let sessionID: UUID
    private let capacity: Int
    private let report:
        @Sendable (StoreTransactionBackgroundFailure) async
            -> Void
    private var queue: [Item] = []
    private var spaceWaiters: [ProcessingReceipt<Void>] = []
    private var worker: Task<Void, Never>?
    private var acceptsFailures = true

    package init(
        sessionID: UUID = UUID(),
        capacity: Int = 32,
        report:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async
            -> Void
    ) {
        precondition(capacity > 0)
        self.sessionID = sessionID
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

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            await drainQueue()
        }
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
                await report(item.failure)
            }
            item.receipt.succeed(())
        }
        worker = nil
    }

    isolated deinit {
        worker?.cancel()
    }
}
