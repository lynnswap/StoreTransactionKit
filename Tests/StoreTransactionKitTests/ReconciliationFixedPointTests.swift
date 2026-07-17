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
        #expect(await currentQueryCount.value() == 1)
        #expect(await unfinishedQueryCount.value() == 4)
        #expect(await reports.snapshot().isEmpty)
    }

    @Test("only the stable query reports current entitlement verification failures")
    func reportsStableVerificationFailuresOnce() async throws {
        let first = makeSnapshot(
            id: 43,
            productID: "lifetime.first",
            productType: .nonConsumable,
            jws: "fixed-point-verification-first"
        )
        let second = makeSnapshot(
            id: 47,
            productID: "lifetime.second",
            productType: .nonConsumable,
            jws: "fixed-point-verification-second"
        )
        let current = EntitlementValueSource([])
        let unfinished = UnfinishedValueSource()
        let currentQueryCount = TestSignal()
        let unfinishedQueryCount = TestSignal()
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reports = StringRecorder()

        let persistentFirst = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: first)
        )
        let persistentSecond = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: second)
        )
        let secondDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: second) {
                await current.replace(with: [first, second])
                await unfinished.replace(
                    with: [persistentFirst, persistentSecond]
                )
                await finishes.send()
            }
        )
        let firstDelivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: first) {
                await current.replace(with: [first])
                await unfinished.replace(with: [persistentFirst])
                await finishes.send()
            }
        )
        await unfinished.replace(with: [firstDelivery])

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
                if queryNumber == 1 {
                    await unfinished.replace(
                        with: [persistentFirst, secondDelivery]
                    )
                }
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
        #expect(snapshots == [first, second])
        #expect(await currentQueryCount.value() == 2)
        #expect(await unfinishedQueryCount.value() == 5)
        #expect(await handlerCalls.value() == 2)
        #expect(await finishes.value() == 2)
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

    @Test("unfinished work is durable before a current entitlement query failure")
    func handlesUnfinishedBeforeCurrentQueryFailure() async throws {
        let snapshot = makeSnapshot(
            id: 48,
            productID: "consumable.before-query-failure",
            productType: .consumable,
            jws: "unfinished-before-query-failure"
        )
        let unfinished = UnfinishedValueSource()
        let events = StringRecorder()
        let reports = StringRecorder()
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await events.append("finish")
                await unfinished.replace(with: [])
            }
        )
        await unfinished.replace(with: [delivery])

        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await events.append("handle")
        }
        let failures = FailureReporterDispatcher { failure in
            await reports.append("\(failure.source)")
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                await events.append("current-entitlements")
                throw CurrentEntitlementQueryFailure()
            },
            queryUnfinished: {
                await events.append("unfinished")
                return await unfinished.read()
            },
            core: core,
            failures: failures
        )

        await #expect(throws: CurrentEntitlementQueryFailure.self) {
            _ = try await reconciler.query(
                retryFailedTransactions: false
            )
        }

        #expect(
            await events.snapshot() == [
                "unfinished",
                "handle",
                "finish",
                "unfinished",
                "current-entitlements",
            ])
        #expect(await reports.snapshot().isEmpty)
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
            revision: Data("persistent-unverified".utf8),
            error: PersistentUnfinishedVerificationFailure()
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
        #expect(await currentQueryCount.value() == 1)
        #expect(await unfinishedQueryCount.value() == 3)
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["unverified"])
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
    }

    @Test("an observed unverified unfinished delivery is reported after it disappears")
    func disappearingUnverifiedUnfinishedIsReported() async throws {
        let snapshot = makeSnapshot(
            id: 49,
            productID: "lifetime.disappearing-verification",
            productType: .nonConsumable,
            jws: "disappearing-unfinished-verification"
        )
        let current = EntitlementValueSource([])
        let unfinished = UnfinishedValueSource()
        let reports = StringRecorder()
        let unverified = StoreTransactionDelivery.unverified(
            revision: Data("disappearing-unverified".utf8),
            error: DisappearingUnfinishedVerificationFailure()
        )
        let verified = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await current.replace(with: [snapshot])
                await unfinished.replace(with: [])
            }
        )
        await unfinished.replace(with: [unverified, verified])

        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in }
        let failures = FailureReporterDispatcher { failure in
            guard failure.source == .unfinished,
                failure.transactionID == nil,
                failure.productID == nil,
                failure.underlyingError
                    is DisappearingUnfinishedVerificationFailure
            else {
                await reports.append("unexpected")
                return
            }
            await reports.append("unverified")
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                CurrentEntitlementQueryResult(
                    snapshots: await current.read(),
                    verificationFailures: []
                )
            },
            queryUnfinished: { await unfinished.read() },
            core: core,
            failures: failures
        )

        let snapshots = try await reconciler.query(
            retryFailedTransactions: false
        )

        #expect(snapshots == [snapshot])
        #expect(await reports.snapshot() == ["unverified"])
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
    }

    @Test("a terminal handler failure preserves verification diagnostics")
    func handlerFailurePreservesVerificationDiagnostics() async throws {
        let snapshot = makeSnapshot(
            id: 46,
            productID: "consumable.diagnostics",
            productType: .consumable
        )
        let finishes = TestSignal()
        let reports = StringRecorder()
        let unfinishedQueryCount = TestSignal()
        let currentFailure = StoreTransactionVerificationError(
            underlyingError: TerminalCurrentVerificationFailure()
        )
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            throw TestFailure()
        }
        let failures = FailureReporterDispatcher { failure in
            switch failure.source {
            case .unfinished:
                if failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("handler")
                } else if failure.transactionID == nil,
                    failure.underlyingError
                        is TerminalUnfinishedVerificationFailure
                {
                    await reports.append("unfinished-verification")
                } else {
                    await reports.append("unexpected")
                }
            case .currentEntitlementVerification:
                guard
                    let verificationFailure =
                        failure.underlyingError
                        as? StoreTransactionVerificationError,
                    verificationFailure.underlyingError
                        is TerminalCurrentVerificationFailure
                else {
                    await reports.append("unexpected")
                    return
                }
                await reports.append("current-verification")
            default:
                await reports.append("unexpected")
            }
        }
        let reconciler = CurrentEntitlementReconciler(
            query: {
                CurrentEntitlementQueryResult(
                    snapshots: [],
                    verificationFailures: [currentFailure]
                )
            },
            queryUnfinished: {
                await unfinishedQueryCount.send()
                guard await unfinishedQueryCount.value() > 1 else {
                    return []
                }
                return [
                    .unverified(
                        revision: Data("terminal-unverified".utf8),
                        error: TerminalUnfinishedVerificationFailure()
                    ),
                    .verified(
                        makeEnvelope(snapshot: snapshot) {
                            await finishes.send()
                        }),
                ]
            },
            core: core,
            failures: failures
        )

        do {
            _ = try await reconciler.query(
                retryFailedTransactions: false
            )
            Issue.record("A failed handler unexpectedly reconciled.")
        } catch let owned as StoreTransactionFailureWithReportingOwner {
            #expect(owned.underlyingError is TestFailure)
        } catch {
            Issue.record("Unexpected reconciliation error: \(error)")
        }

        #expect(await finishes.value() == 0)
        #expect(
            await reports.snapshot() == [
                "handler",
                "unfinished-verification",
                "current-verification",
            ])
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
    }
}

private struct DiscardedVerificationFailure: Error, Sendable {}

private struct StableVerificationFailure: Error, Sendable {}

private struct PersistentUnfinishedVerificationFailure: Error, Sendable {}

private struct DisappearingUnfinishedVerificationFailure: Error, Sendable {}

private struct TerminalUnfinishedVerificationFailure: Error, Sendable {}

private struct TerminalCurrentVerificationFailure: Error, Sendable {}

private struct CurrentEntitlementQueryFailure: Error, Sendable {}
