import StoreKit
import Testing
@testable import StoreTransactionKit

@Suite("Current entitlement reconciliation fixed point", .timeLimit(.minutes(1)))
struct ReconciliationFixedPointTests {
    @Test("reconciliation repeats until no new entitlement revision remains")
    func repeatsUntilNoNewRevision() async throws {
        let first = makeSnapshot(
            id: 41,
            productID: "lifetime.first",
            productType: .nonConsumable,
            jws: "fixed-point-first"
        )
        let second = makeSnapshot(
            id: 42,
            productID: "lifetime.second",
            productType: .nonConsumable,
            jws: "fixed-point-second"
        )
        let current = EntitlementValueSource([])
        let unfinished = UnfinishedValueSource()
        let currentQueryCount = TestSignal()
        let unfinishedQueryCount = TestSignal()
        let handled = UInt64Recorder()
        let finished = UInt64Recorder()
        let reports = StringRecorder()

        let persistentFirst = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: first)
        )
        let secondDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: second) {
                await finished.append(second.id)
            }
        )
        let firstDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: first) {
                await finished.append(first.id)
                await current.replace(with: [first, second])
                await unfinished.replace(
                    with: [persistentFirst, secondDelivery]
                )
            }
        )
        await unfinished.replace(with: [firstDelivery])

        let core = TransactionProcessingCore<StoreTransactionSnapshot> { snapshot in
            await handled.append(snapshot.id)
        }
        let failures = FailureReporterDispatcher { failure in
            await reports.append("\(failure.source)")
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                await currentQueryCount.send()
                return CurrentEntitlementQueryResult(
                    snapshots: await current.read(),
                    verificationFailures: []
                )
            },
            queryUnfinished: {
                await unfinishedQueryCount.send()
                return await unfinished.read()
            },
            core: core,
            failures: failures
        )

        let snapshots = try await reconciler.query(
            retryFailedTransactions: false
        )

        await core.finishInputAndDrain()
        await failures.sealAndDrain()
        #expect(snapshots == [first, second])
        #expect(await handled.snapshot() == [first.id, second.id])
        #expect(await finished.snapshot() == [first.id, second.id])
        #expect(await currentQueryCount.value() == 3)
        #expect(await unfinishedQueryCount.value() == 3)
        #expect(await reports.snapshot().isEmpty)
    }

    @Test("only the stable query reports current entitlement verification failures")
    func reportsStableVerificationFailuresOnce() async throws {
        let snapshot = makeSnapshot(
            id: 43,
            productID: "lifetime.verified",
            productType: .nonConsumable,
            jws: "fixed-point-verification"
        )
        let current = EntitlementValueSource([])
        let unfinished = UnfinishedValueSource()
        let currentQueryCount = TestSignal()
        let unfinishedQueryCount = TestSignal()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()

        let persistentDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot)
        )
        let initialDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await current.replace(with: [snapshot])
                await unfinished.replace(with: [persistentDelivery])
                await finishes.send()
            }
        )
        await unfinished.replace(with: [initialDelivery])

        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
        }
        let failures = FailureReporterDispatcher { failure in
            guard failure.source == .currentEntitlementVerification,
                let verificationFailure =
                    failure.underlyingError as? StoreTransactionVerificationError
            else {
                await reports.append("unexpected")
                return
            }
            switch verificationFailure.underlyingError {
            case is DiscardedVerificationFailure:
                await reports.append("discarded")
            case is StableVerificationFailure:
                await reports.append("stable")
            default:
                await reports.append("unexpected")
            }
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                await currentQueryCount.send()
                let queryNumber = await currentQueryCount.value()
                let underlyingError: any Error =
                    if queryNumber == 1 {
                        DiscardedVerificationFailure()
                    } else {
                        StableVerificationFailure()
                    }
                return CurrentEntitlementQueryResult(
                    snapshots: await current.read(),
                    verificationFailures: [
                        StoreTransactionVerificationError(
                            underlyingError: underlyingError
                        )
                    ]
                )
            },
            queryUnfinished: {
                await unfinishedQueryCount.send()
                return await unfinished.read()
            },
            core: core,
            failures: failures
        )

        let snapshots = try await reconciler.query(
            retryFailedTransactions: false
        )

        await core.finishInputAndDrain()
        await failures.sealAndDrain()
        #expect(snapshots == [snapshot])
        #expect(await currentQueryCount.value() == 2)
        #expect(await unfinishedQueryCount.value() == 2)
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["stable"])
    }

    @Test("a failed unfinished consumable blocks readiness and remains retryable")
    func failedUnfinishedConsumableIsRetryable() async throws {
        let snapshot = makeSnapshot(
            id: 44,
            productID: "consumable.tokens",
            productType: .consumable,
            jws: "unfinished-consumable"
        )
        let unfinished = UnfinishedValueSource()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await finishes.send()
                await unfinished.replace(with: [])
            }
        )
        await unfinished.replace(with: [delivery])

        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
            if await handlerCalls.value() == 1 {
                throw TestFailure()
            }
        }
        let failures = FailureReporterDispatcher { failure in
            guard failure.source == .unfinished,
                failure.transactionID == snapshot.id,
                failure.productID == snapshot.productID,
                failure.underlyingError is TestFailure
            else {
                await reports.append("unexpected")
                return
            }
            await reports.append("unfinished-\(snapshot.id)")
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                CurrentEntitlementQueryResult(
                    snapshots: [],
                    verificationFailures: []
                )
            },
            queryUnfinished: { await unfinished.read() },
            core: core,
            failures: failures
        )

        do {
            _ = try await reconciler.query(
                retryFailedTransactions: false
            )
            Issue.record("A failed unfinished transaction unexpectedly reconciled.")
        } catch let owned as StoreTransactionFailureWithReportingOwner {
            #expect(owned.underlyingError is TestFailure)
        } catch {
            Issue.record("Unexpected reconciliation error: \(error)")
        }
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 0)
        #expect(await reports.snapshot() == ["unfinished-44"])

        let snapshots = try await reconciler.query(
            retryFailedTransactions: true
        )

        #expect(snapshots.isEmpty)
        #expect(await handlerCalls.value() == 2)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["unfinished-44"])
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
    }

    @Test("a persistent unverified unfinished delivery is reported by the stable query once")
    func persistentUnverifiedUnfinishedReportsOnce() async throws {
        let snapshot = makeSnapshot(
            id: 45,
            productID: "lifetime.verified",
            productType: .nonConsumable,
            jws: "unfinished-verification-fixed-point"
        )
        let current = EntitlementValueSource([])
        let unfinished = UnfinishedValueSource()
        let currentQueryCount = TestSignal()
        let unfinishedQueryCount = TestSignal()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()
        let unverified = StoreTransactionDelivery.unverified(
            PersistentUnfinishedVerificationFailure()
        )
        let verified = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await finishes.send()
                await current.replace(with: [snapshot])
                await unfinished.replace(with: [unverified])
            }
        )
        await unfinished.replace(with: [unverified, verified])

        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
        }
        let failures = FailureReporterDispatcher { failure in
            guard failure.source == .unfinished,
                failure.transactionID == nil,
                failure.productID == nil,
                failure.underlyingError
                    is PersistentUnfinishedVerificationFailure
            else {
                await reports.append("unexpected")
                return
            }
            await reports.append("unverified")
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                await currentQueryCount.send()
                return CurrentEntitlementQueryResult(
                    snapshots: await current.read(),
                    verificationFailures: []
                )
            },
            queryUnfinished: {
                await unfinishedQueryCount.send()
                return await unfinished.read()
            },
            core: core,
            failures: failures
        )

        let snapshots = try await reconciler.query(
            retryFailedTransactions: false
        )

        #expect(snapshots == [snapshot])
        #expect(await currentQueryCount.value() == 2)
        #expect(await unfinishedQueryCount.value() == 2)
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["unverified"])
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
    }
}

private struct DiscardedVerificationFailure: Error, Sendable {}

private struct StableVerificationFailure: Error, Sendable {}

private struct PersistentUnfinishedVerificationFailure: Error, Sendable {}
