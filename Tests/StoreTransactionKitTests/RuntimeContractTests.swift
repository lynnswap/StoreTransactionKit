import Foundation
import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Runtime contracts", .timeLimit(.minutes(1)))
struct RuntimeContractTests {
    @Test("receipt waiter cancellation is distinct from terminal cancellation failure")
    func receiptCancellationIdentity() async throws {
        let terminalFailure = ProcessingReceipt<Void>()
        terminalFailure.fail(CancellationError())

        do {
            try await terminalFailure.value()
            Issue.record("A terminal cancellation failure unexpectedly succeeded.")
        } catch is ProcessingReceiptWaiterCancellation {
            Issue.record("A terminal failure was mistaken for waiter cancellation.")
        } catch is CancellationError {
            // The dependency's terminal failure remains intact.
        } catch {
            Issue.record("Unexpected terminal receipt error: \(error)")
        }

        let pending = ProcessingReceipt<Void>()
        let gate = TestGate()
        let waiter = Task {
            _ = try? await gate.wait()
            do {
                try await pending.value()
                return false
            } catch is ProcessingReceiptWaiterCancellation {
                return true
            } catch {
                Issue.record("Unexpected cancelled waiter error: \(error)")
                return false
            }
        }
        waiter.cancel()
        await gate.open()

        #expect(await waiter.value)
    }

    @Test("immediate purchase outcomes return their semantic values")
    func immediatePurchaseOutcomes() async throws {
        let fixture = TestSourceFixture()
        let handlerCalls = TestSignal()
        let reports = StringRecorder()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
            },
            reportFailure: { failure in
                await reports.append("\(failure.source)")
            }
        )
        _ = try await session.start()

        let pending = try await session.process(.pending)
        let userCancelled = try await session.process(.userCancelled)

        #expect(pending == .pending)
        #expect(userCancelled == .userCancelled)
        #expect(await handlerCalls.value() == 0)
        #expect(await fixture.entitlementQueryCount.value() == 1)
        #expect(await reports.snapshot().isEmpty)
        try await session.close()
    }

    @Test("immediate purchase outcomes honor caller cancellation")
    func immediatePurchaseOutcomeCancellation() async throws {
        let fixture = TestSourceFixture()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        _ = try await session.start()

        for result: Product.PurchaseResult in [.pending, .userCancelled] {
            let gate = TestGate()
            let process = Task {
                _ = try? await gate.wait()
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
        let entitlementQueryCount = TestSignal()
        let entitlements = EntitlementRefreshCoordinator(
            query: { _ in
                await entitlementQueryCount.send()
                return []
            },
            didChange: { _ in }
        )
        let coordinator = RestoreCoordinator(
            synchronize: {
                await synchronizationStarted.send()
                try await synchronizationGate.wait()
            },
            entitlements: entitlements
        )

        let first = await coordinator.reserve()
        try await synchronizationStarted.wait(for: 1)
        let second = await coordinator.reserve()

        #expect(first.role == .owner)
        #expect(second.role == .observer)
        #expect(first.receipt === second.receipt)

        await synchronizationGate.open()
        let firstValue = try await first.receipt.terminalValue()
        let secondValue = try await second.receipt.terminalValue()

        #expect(firstValue == secondValue)
        #expect(await synchronizationStarted.value() == 1)
        #expect(await entitlementQueryCount.value() == 1)
        await entitlements.sealAndDrain()
    }

    @Test("a cancelled restore observer does not report an attached failure")
    func cancelledRestoreObserverDoesNotReportAttachedFailure() async throws {
        let synchronizationStarted = TestSignal()
        let synchronizationGate = TestGate()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            synchronize: {
                await synchronizationStarted.send()
                try await synchronizationGate.wait()
                throw TestFailure()
            }
        )
        let runtime = StoreTransactionRuntime(
            sessionID: UUID(),
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                switch failure.source {
                case .abandonedDirectOperation(.restorePurchases):
                    await reports.append("restore")
                default:
                    await reports.append("unexpected")
                }
            }
        )
        _ = try await runtime.readiness()

        let ownerLeases = try #require(runtime.beginOperation())
        let owner = Task {
            try await runtime.restorePurchases(leases: ownerLeases)
        }
        try await synchronizationStarted.wait(for: 1)

        let observerLeases = try #require(runtime.beginOperation())
        let observer = Task {
            try await runtime.restorePurchases(leases: observerLeases)
        }
        observer.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await observer.value
        }

        await synchronizationGate.open()
        await #expect(throws: TestFailure.self) {
            _ = try await owner.value
        }
        await runtime.close()

        #expect(await reports.snapshot().isEmpty)
    }

    @Test("cancelled coalesced restore callers report one physical failure")
    func cancelledRestoreCallersReportOnce() async throws {
        let synchronizationStarted = TestSignal()
        let synchronizationGate = TestGate()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            synchronize: {
                await synchronizationStarted.send()
                try await synchronizationGate.wait()
                throw TestFailure()
            }
        )
        let runtime = StoreTransactionRuntime(
            sessionID: UUID(),
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                switch failure.source {
                case .abandonedDirectOperation(.restorePurchases):
                    await reports.append("restore")
                default:
                    await reports.append("unexpected")
                }
            }
        )
        _ = try await runtime.readiness()

        let ownerLeases = try #require(runtime.beginOperation())
        let owner = Task {
            try await runtime.restorePurchases(leases: ownerLeases)
        }
        try await synchronizationStarted.wait(for: 1)
        owner.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await owner.value
        }

        let observerLeases = try #require(runtime.beginOperation())
        let observer = Task {
            try await runtime.restorePurchases(leases: observerLeases)
        }
        observer.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await observer.value
        }

        await synchronizationGate.open()
        await runtime.close()

        #expect(await reports.snapshot() == ["restore"])
    }

    @Test("an abandoned refresh reports its later failure exactly once")
    func abandonedRefreshFailure() async throws {
        let query = ControlledEntitlementQuery()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
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
        try await query.waitForRequest(1)
        await query.succeed([])
        _ = try await startup.value

        let refresh = Task { try await session.currentEntitlements() }
        try await query.waitForRequest(2)
        refresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await refresh.value
        }
        await query.fail(TestFailure())
        try await reported.wait(for: 1)

        try await session.close()
        #expect(await reports.snapshot() == ["abandoned-refresh"])
    }

    @Test("an attached refresh receives the reported underlying failure and can retry")
    func attachedRefreshUnwrapsReportedFailure() async throws {
        let unfinished = UnfinishedValueSource()
        let fixture = TestSourceFixture(
            queryUnfinished: { await unfinished.read() }
        )
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()
        let snapshot = makeSnapshot(
            id: 26,
            productID: "consumable.refresh",
            productType: .consumable
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
                if await handlerCalls.value() == 1 {
                    throw TestFailure()
                }
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-26")
                } else {
                    await reports.append("unexpected")
                }
            }
        )
        _ = try await session.start()
        await unfinished.replace(
            with: [
                .verified(
                    makeEnvelope(snapshot: snapshot) {
                        await finishes.send()
                        await unfinished.replace(with: [])
                    })
            ]
        )

        await #expect(throws: TestFailure.self) {
            _ = try await session.currentEntitlements()
        }
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 0)
        #expect(await reports.snapshot() == ["unfinished-26"])

        let entitlements = try await session.currentEntitlements()

        #expect(entitlements.transactions.isEmpty)
        #expect(await handlerCalls.value() == 2)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-26"])
        try await session.close()
    }

    @Test("a direct process unwraps a reported refresh failure and can retry")
    func directProcessUnwrapsReportedRefreshFailure() async throws {
        let unfinished = UnfinishedValueSource()
        let fixture = TestSourceFixture(
            queryUnfinished: { await unfinished.read() }
        )
        let handled = UInt64Recorder()
        let consumableAttempts = TestSignal()
        let directFinishes = TestSignal()
        let consumableFinishes = TestSignal()
        let reports = StringRecorder()
        let direct = makeSnapshot(
            id: 27,
            productID: "lifetime.direct",
            productType: .nonConsumable
        )
        let consumable = makeSnapshot(
            id: 28,
            productID: "consumable.process",
            productType: .consumable
        )
        let runtime = StoreTransactionRuntime(
            sessionID: UUID(),
            source: fixture.source,
            handleTransaction: { snapshot in
                await handled.append(snapshot.id)
                if snapshot.id == consumable.id {
                    await consumableAttempts.send()
                    if await consumableAttempts.value() == 1 {
                        throw TestFailure()
                    }
                }
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == consumable.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-28")
                } else {
                    await reports.append("unexpected")
                }
            }
        )
        _ = try await runtime.readiness()
        await unfinished.replace(
            with: [
                .verified(
                    makeEnvelope(snapshot: consumable) {
                        await consumableFinishes.send()
                        await unfinished.replace(with: [])
                    })
            ]
        )
        let directDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: direct) {
                await directFinishes.send()
            }
        )

        let firstLeases = try #require(runtime.beginOperation())
        await #expect(throws: TestFailure.self) {
            _ = try await runtime.process(
                directDelivery,
                leases: firstLeases
            )
        }
        #expect(await handled.snapshot() == [direct.id, consumable.id])
        #expect(await directFinishes.value() == 1)
        #expect(await consumableFinishes.value() == 0)
        #expect(await reports.snapshot() == ["unfinished-28"])

        let secondLeases = try #require(runtime.beginOperation())
        let outcome = try await runtime.process(
            directDelivery,
            leases: secondLeases
        )

        #expect(outcome == .completed(direct))
        #expect(
            await handled.snapshot() == [
                direct.id, consumable.id, consumable.id,
            ]
        )
        #expect(await directFinishes.value() == 1)
        #expect(await consumableFinishes.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-28"])
        await runtime.close()
    }

    @Test("restore unwraps a reported refresh failure and can retry")
    func restoreUnwrapsReportedRefreshFailure() async throws {
        let unfinished = UnfinishedValueSource()
        let synchronizations = TestSignal()
        let fixture = TestSourceFixture(
            queryUnfinished: { await unfinished.read() },
            synchronize: { await synchronizations.send() }
        )
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()
        let snapshot = makeSnapshot(
            id: 29,
            productID: "consumable.restore",
            productType: .consumable
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
                if await handlerCalls.value() == 1 {
                    throw TestFailure()
                }
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-29")
                } else {
                    await reports.append("unexpected")
                }
            }
        )
        _ = try await session.start()
        await unfinished.replace(
            with: [
                .verified(
                    makeEnvelope(snapshot: snapshot) {
                        await finishes.send()
                        await unfinished.replace(with: [])
                    })
            ]
        )

        await #expect(throws: TestFailure.self) {
            _ = try await session.restorePurchases()
        }
        #expect(await synchronizations.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-29"])

        let entitlements = try await session.restorePurchases()

        #expect(entitlements.transactions.isEmpty)
        #expect(await synchronizations.value() == 2)
        #expect(await handlerCalls.value() == 2)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-29"])
        try await session.close()
    }

    @Test("an abandoned refresh does not report an owned reconciliation failure twice")
    func abandonedRefreshDoesNotDuplicateReportedFailure() async throws {
        let unfinished = UnfinishedValueSource()
        let fixture = TestSourceFixture(
            queryUnfinished: { await unfinished.read() }
        )
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let reported = TestSignal()
        let reports = StringRecorder()
        let snapshot = makeSnapshot(
            id: 30,
            productID: "consumable.abandoned",
            productType: .consumable
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerStarted.send()
                try await handlerGate.wait()
                throw TestFailure()
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-30")
                } else {
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )
        _ = try await session.start()
        await unfinished.replace(
            with: [.verified(makeEnvelope(snapshot: snapshot))]
        )

        let refresh = Task {
            try await session.currentEntitlements()
        }
        try await handlerStarted.wait(for: 1)
        refresh.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await refresh.value
        }

        await handlerGate.open()
        try await reported.wait(for: 1)
        try await session.close()

        #expect(await reports.snapshot() == ["unfinished-30"])
    }

    @Test("an abandoned restore does not report an owned reconciliation failure twice")
    func abandonedRestoreDoesNotDuplicateReportedFailure() async throws {
        let unfinished = UnfinishedValueSource()
        let synchronizations = TestSignal()
        let fixture = TestSourceFixture(
            queryUnfinished: { await unfinished.read() },
            synchronize: { await synchronizations.send() }
        )
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let reported = TestSignal()
        let reports = StringRecorder()
        let snapshot = makeSnapshot(
            id: 32,
            productID: "consumable.abandoned-restore",
            productType: .consumable
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerStarted.send()
                try await handlerGate.wait()
                throw TestFailure()
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-32")
                } else {
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )
        _ = try await session.start()
        await unfinished.replace(
            with: [.verified(makeEnvelope(snapshot: snapshot))]
        )

        let restore = Task {
            try await session.restorePurchases()
        }
        try await handlerStarted.wait(for: 1)
        restore.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await restore.value
        }

        await handlerGate.open()
        try await reported.wait(for: 1)
        try await session.close()

        #expect(await synchronizations.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-32"])
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
        try await query.waitForRequest(1)
        await query.succeed([])
        _ = try await startup.value

        fixture.updates.yield(
            .verified(makeEnvelope(snapshot: makeSnapshot(id: 19)))
        )
        try await query.waitForRequest(2)
        await query.fail(TestFailure())
        try await reported.wait(for: 1)

        try await session.close()
        #expect(await reports.snapshot() == ["entitlementRefresh-19-product"])
    }

    @Test("an update owner prevents an observer refresh from reporting the same failure")
    func observerRefreshUsesTransactionReportingOwner() async throws {
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let reports = StringRecorder()
        let snapshot = makeSnapshot(
            id: 31,
            productID: "consumable.observer",
            productType: .consumable
        )
        let envelope = makeEnvelope(snapshot: snapshot)
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerStarted.send()
            try await handlerGate.wait()
            throw TestFailure()
        }
        let failures = FailureReporterDispatcher { failure in
            switch failure.source {
            case .updates where failure.underlyingError is TestFailure:
                await reports.append("updates")
            case .unfinished, .entitlementRefresh,
                .abandonedDirectOperation:
                await reports.append("duplicate")
            default:
                await reports.append("unexpected")
            }
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                CurrentEntitlementQueryResult(
                    snapshots: [],
                    verificationFailures: []
                )
            },
            queryUnfinished: { [] },
            core: core,
            failures: failures
        )

        let owner = await core.accept(envelope)
        try await handlerStarted.wait(for: 1)
        let observer = await core.accept(envelope)
        #expect(owner.role == .owner)
        #expect(observer.role == .inFlightObserver)

        let entitlements = EntitlementRefreshCoordinator(
            query: { _ in
                try await reconciler.drain([
                    CurrentEntitlementReconciler.AcceptedTransaction(
                        snapshot: snapshot,
                        acceptance: observer
                    )
                ])
                return []
            },
            didChange: { _ in }
        )
        let pipeline = StoreTransactionPipeline(
            core: core,
            entitlements: entitlements,
            failures: failures
        )
        let update = Task {
            await pipeline.processAcceptedBackground(
                snapshot: snapshot,
                acceptance: owner,
                source: .updates
            )
        }
        let subscriptionRefresh = Task {
            await pipeline.refreshEntitlements()
        }

        await handlerGate.open()
        await update.value
        await subscriptionRefresh.value

        #expect(await reports.snapshot() == ["updates"])
        await core.finishInputAndDrain()
        await entitlements.sealAndDrain()
        await failures.sealAndDrain()
    }

    @Test("reconciliation requeries after handling a newly unfinished revision")
    func reconciliationRequeriesAfterUnfinishedHandling() async throws {
        let entitlementQueryCount = TestSignal()
        let unfinishedQueryStarted = TestSignal()
        let unfinishedQueryGate = TestGate()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let currentEntitlements = EntitlementValueSource([])
        let reports = StringRecorder()
        let snapshot = makeSnapshot(
            id: 24,
            productType: .nonConsumable
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "arrived-after-query") {
                await currentEntitlements.replace(with: [snapshot])
                await finishes.send()
            }
        )
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
        }
        let failures = FailureReporterDispatcher { failure in
            await reports.append("\(failure.source)")
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                await entitlementQueryCount.send()
                return CurrentEntitlementQueryResult(
                    snapshots: await currentEntitlements.read(),
                    verificationFailures: []
                )
            },
            queryUnfinished: {
                await unfinishedQueryStarted.send()
                _ = try? await unfinishedQueryGate.wait()
                return [delivery]
            },
            core: core,
            failures: failures
        )

        let query = Task {
            try await reconciler.query(retryFailedTransactions: false)
        }
        try await unfinishedQueryStarted.wait(for: 1)
        #expect(await entitlementQueryCount.value() == 1)

        await unfinishedQueryGate.open()
        let snapshots = try await query.value

        #expect(snapshots == [snapshot])
        #expect(await entitlementQueryCount.value() == 2)
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 1)
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
        #expect(await reports.snapshot().isEmpty)
    }

    @Test("duplicate background deliveries report one handler failure")
    func duplicateBackgroundDeliveryFailure() async throws {
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
            await handlerStarted.send()
            try await handlerGate.wait()
            throw TestFailure()
        }
        let entitlements = EntitlementRefreshCoordinator(
            query: { _ in
                Issue.record("A failed transaction unexpectedly refreshed entitlements.")
                return []
            },
            didChange: { _ in }
        )
        let failures = FailureReporterDispatcher { failure in
            switch failure.source {
            case .updates:
                await reports.append("updates")
            case .unfinished:
                await reports.append("unfinished")
            default:
                await reports.append("unexpected")
            }
        }
        let pipeline = StoreTransactionPipeline(
            core: core,
            entitlements: entitlements,
            failures: failures
        )
        let snapshot = makeSnapshot(id: 21)
        let update = try await pipeline.accept(
            .verified(
                makeEnvelope(snapshot: snapshot, revision: "same") {
                    await finishes.send()
                })
        )
        try await handlerStarted.wait(for: 1)
        let unfinished = try await pipeline.accept(
            .verified(
                makeEnvelope(snapshot: snapshot, revision: "same") {
                    await finishes.send()
                })
        )

        #expect(update.acceptance.role == .owner)
        #expect(unfinished.acceptance.role == .inFlightObserver)

        let updateTask = Task {
            await pipeline.processAcceptedBackground(
                snapshot: update.snapshot,
                acceptance: update.acceptance,
                source: .updates
            )
        }
        let unfinishedTask = Task {
            await pipeline.processAcceptedBackground(
                snapshot: unfinished.snapshot,
                acceptance: unfinished.acceptance,
                source: .unfinished
            )
        }
        await handlerGate.open()
        await updateTask.value
        await unfinishedTask.value

        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 0)
        #expect(await reports.snapshot() == ["updates"])

        await core.finishInputAndDrain()
        await entitlements.sealAndDrain()
        await failures.sealAndDrain()
    }

    @Test("a later delivery retries after an earlier handler attempt fails")
    func laterDeliveryRetriesFailedRevision() async {
        let handlerCalls = TestSignal()
        let reports = StringRecorder()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
            throw TestFailure()
        }
        let entitlements = EntitlementRefreshCoordinator(
            query: { _ in
                Issue.record("A failed transaction unexpectedly refreshed entitlements.")
                return []
            },
            didChange: { _ in }
        )
        let failures = FailureReporterDispatcher { failure in
            await reports.append("\(failure.source)")
        }
        let pipeline = StoreTransactionPipeline(
            core: core,
            entitlements: entitlements,
            failures: failures
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: makeSnapshot(id: 22), revision: "retry")
        )

        await pipeline.processBackground(delivery, source: .updates)
        await core.completeInitialAttempt()
        await pipeline.processBackground(delivery, source: .unfinished)

        #expect(await handlerCalls.value() == 2)
        #expect(await reports.snapshot() == ["updates", "unfinished"])
        await core.finishInputAndDrain()
        await entitlements.sealAndDrain()
        await failures.sealAndDrain()
    }

    @Test("a cancelled direct observer leaves failure reporting with the background owner")
    func directObserverCancellationDoesNotDuplicateFailure() async throws {
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let handlerCalls = TestSignal()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture()
        let runtime = StoreTransactionRuntime(
            sessionID: UUID(),
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
                await handlerStarted.send()
                try await handlerGate.wait()
                throw TestFailure()
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                await reports.append("\(failure.source)")
                await reported.send()
            }
        )
        _ = try await runtime.readiness()
        let snapshot = makeSnapshot(id: 23)
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "shared")
        )
        fixture.updates.yield(delivery)
        try await handlerStarted.wait(for: 1)

        let leases = try #require(runtime.beginOperation())
        let directObserver = Task {
            try await runtime.process(delivery, leases: leases)
        }
        directObserver.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await directObserver.value
        }

        await handlerGate.open()
        try await reported.wait(for: 1)
        await runtime.close()

        #expect(await handlerCalls.value() == 1)
        #expect(await reports.snapshot() == ["updates"])
    }

    @Test("a cancelled completed observer reports its own refresh failure")
    func completedObserverCancellationReportsRefreshFailure() async throws {
        let query = ControlledEntitlementQuery()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let runtime = StoreTransactionRuntime(
            sessionID: UUID(),
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                switch failure.source {
                case .abandonedDirectOperation(.processPurchase):
                    await reports.append("abandoned-process")
                default:
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )

        let readiness = Task { try await runtime.readiness() }
        try await query.waitForRequest(1)
        await query.succeed([])
        _ = try await readiness.value

        let snapshot = makeSnapshot(
            id: 25,
            productType: .nonConsumable
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot, revision: "completed") {
                await finishes.send()
            }
        )
        let firstLeases = try #require(runtime.beginOperation())
        let firstProcess = Task {
            try await runtime.process(delivery, leases: firstLeases)
        }
        try await query.waitForRequest(2)
        await query.succeed([snapshot])
        _ = try await firstProcess.value

        let secondLeases = try #require(runtime.beginOperation())
        let completedObserver = Task {
            try await runtime.process(delivery, leases: secondLeases)
        }
        try await query.waitForRequest(3)
        completedObserver.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await completedObserver.value
        }
        await query.fail(TestFailure())
        try await reported.wait(for: 1)

        await runtime.close()
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["abandoned-process"])
    }

    @Test("close completes after accepted handling and finish")
    func closeDrainsAcceptedTransaction() async throws {
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let events = StringRecorder()
        let closeCallersStarted = TestSignal()
        let closeCallersFinished = TestSignal()
        let fixture = TestSourceFixture()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await events.append("handle-start")
                await handlerStarted.send()
                try await handlerGate.wait()
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
        try await handlerStarted.wait(for: 1)

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
        try await closeCallersStarted.wait(for: 2)
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

@Suite("Task completion bag", .timeLimit(.minutes(1)))
struct TaskCompletionBagTests {
    @Test("completed tasks are released when the bag becomes empty")
    func completedTasksAreReleased() async throws {
        let bag = TaskCompletionBag()
        let completed = TestSignal()

        for _ in 0..<32 {
            bag.insert(
                Task {
                    await completed.send()
                })
        }
        try await completed.wait(for: 32)
        await bag.waitForAll()
        #expect(bag.retainedTaskCount() == 0)
    }
}
