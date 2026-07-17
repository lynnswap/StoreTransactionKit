import Foundation
import Testing
@testable import StoreTransactionKit

@Suite("StoreTransactionSession", .timeLimit(.minutes(1)))
struct StoreTransactionSessionTests {
    @Test("start publishes initial entitlements and close terminates producers")
    func startAndClose() async throws {
        let fixture = TestSourceFixture()
        let publicationSizes = UInt64Recorder()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            },
            reportFailure: { _ in }
        )

        let readiness = try await session.start()
        #expect(readiness.entitlements.transactions.isEmpty)
        #expect(await publicationSizes.snapshot() == [0])

        try await session.close()
        try await fixture.updateTermination.wait(for: 1)
        try await fixture.subscriptionStatusTermination.wait(for: 1)
    }

    @Test("initial entitlement publication joins unfinished processing")
    func initialEntitlementsJoinUnfinishedProcessing() async throws {
        let snapshot = makeSnapshot(id: 41, productID: "subscription.plus")
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let events = StringRecorder()
        let publications = UInt64Recorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { [snapshot] },
            queryUnfinished: {
                [
                    .verified(
                        makeEnvelope(snapshot: snapshot) {
                            await events.append("finish-41")
                        })
                ]
            }
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { transaction in
                await events.append("handle-\(transaction.id)")
                await handlerStarted.send()
                try await handlerGate.wait()
            },
            entitlementsDidChange: { value in
                await publications.append(UInt64(value.transactions.count))
            },
            reportFailure: { failure in
                Issue.record("Unexpected startup failure: \(failure)")
            }
        )

        let startup = Task { try await session.start() }
        try await handlerStarted.wait(for: 1)
        #expect(await publications.snapshot().isEmpty)

        await handlerGate.open()
        let readiness = try await startup.value

        #expect(readiness.entitlements.transactions == [snapshot])
        #expect(await events.snapshot() == ["handle-41", "finish-41"])
        #expect(await publications.snapshot() == [1])
        try await session.close()
    }

    @Test("startup does not retry an update failure through unfinished reconciliation")
    func startupSharesFailedUpdateWithUnfinishedReconciliation() async throws {
        let snapshot = makeSnapshot(
            id: 42,
            productID: "consumable.startup",
            productType: .consumable
        )
        let envelope = makeEnvelope(snapshot: snapshot)
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: {
                try await reported.wait(for: 1)
                return []
            },
            queryUnfinished: {
                [
                    .verified(
                        makeEnvelope(snapshot: snapshot) {
                            await finishes.send()
                        })
                ]
            }
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
                if await handlerCalls.value() == 1 {
                    throw TestFailure()
                }
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                if failure.source == .updates,
                    failure.transactionID == snapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("updates-42")
                } else {
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )

        fixture.updates.yield(.verified(envelope))

        await #expect(throws: TestFailure.self) {
            _ = try await session.start()
        }
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 0)
        #expect(await reports.snapshot() == ["updates-42"])

        _ = try await session.currentEntitlements()

        #expect(await handlerCalls.value() == 2)
        #expect(await finishes.value() == 1)
        #expect(await reports.snapshot() == ["updates-42"])
        try await session.close()
    }

    @Test("cancelling the startup waiter does not open a retry boundary")
    func cancelledStartupWaiterKeepsInitialAttempt() async throws {
        let failedSnapshot = makeSnapshot(
            id: 43,
            productID: "consumable.cancelled-startup",
            productType: .consumable
        )
        let markerSnapshot = makeSnapshot(id: 44)
        let query = ControlledEntitlementQuery()
        let handled = UInt64Recorder()
        let failedFinish = TestSignal()
        let markerFinish = TestSignal()
        let reported = TestSignal()
        let reports = StringRecorder()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() },
            queryUnfinished: {
                [
                    .verified(
                        makeEnvelope(snapshot: failedSnapshot) {
                            await failedFinish.send()
                        })
                ]
            }
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { snapshot in
                await handled.append(snapshot.id)
                if snapshot.id == failedSnapshot.id {
                    throw TestFailure()
                }
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                if failure.source == .updates,
                    failure.transactionID == failedSnapshot.id,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("updates-43")
                } else {
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )

        let startup = Task { try await session.start() }
        try await query.waitForRequest(1)
        fixture.updates.yield(
            .verified(makeEnvelope(snapshot: failedSnapshot))
        )
        try await reported.wait(for: 1)

        startup.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await startup.value
        }

        fixture.updates.yield(
            .verified(makeEnvelope(snapshot: failedSnapshot))
        )
        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: markerSnapshot) {
                    await markerFinish.send()
                })
        )
        try await markerFinish.wait(for: 1)

        #expect(await handled.snapshot() == [43, 44])
        #expect(await failedFinish.value() == 0)
        #expect(await reports.snapshot() == ["updates-43"])

        await query.succeed([])
        try await query.waitForRequest(2)
        await query.succeed([])
        try await session.close()

        #expect(await handled.snapshot() == [43, 44])
        #expect(await failedFinish.value() == 0)
        #expect(await reports.snapshot() == ["updates-43"])
    }

    @Test("subscription status waits for initial entitlement readiness")
    func subscriptionStatusWaitsForReadiness() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                Issue.record("Unexpected status failure: \(failure)")
            }
        )

        let startup = Task { try await session.start() }
        try await query.waitForRequest(1)
        fixture.subscriptionStatusUpdates.yield()
        try await fixture.subscriptionStatusDeliveryCount.wait(for: 1)
        #expect(await fixture.entitlementQueryCount.value() == 1)

        await query.succeed([])
        _ = try await startup.value
        try await query.waitForRequest(2)
        await query.succeed([])

        try await session.close()
    }

    @Test("close cancels a status waiter but drains startup readiness")
    func closeDuringSubscriptionStatusReadiness() async throws {
        let query = ControlledEntitlementQuery()
        let fixture = TestSourceFixture(
            currentEntitlements: { try await query.next() }
        )
        let closeCompleted = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in },
            reportFailure: { _ in }
        )

        let startup = Task { try await session.start() }
        try await query.waitForRequest(1)
        fixture.subscriptionStatusUpdates.yield()
        try await fixture.subscriptionStatusDeliveryCount.wait(for: 1)

        let close = Task {
            try await session.close()
            await closeCompleted.send()
        }
        try await fixture.subscriptionStatusTermination.wait(for: 1)
        #expect(await closeCompleted.value() == 0)

        await query.succeed([])
        do {
            _ = try await startup.value
            Issue.record("Startup unexpectedly completed after close began.")
        } catch StoreTransactionError.closing {
            // Closing owns the runtime after readiness drains.
        }
        try await close.value
        #expect(await closeCompleted.value() == 1)
    }

    @Test("known subscription status changes refresh without replaying handling")
    func knownSubscriptionStatusReconciliation() async throws {
        let snapshot = makeSnapshot(id: 1, productID: "subscription.plus")
        let values = EntitlementValueSource([snapshot])
        let fixture = TestSourceFixture(
            currentEntitlements: { await values.read() }
        )
        let handlerCalls = TestSignal()
        let publications = UInt64Recorder()
        let published = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
            },
            entitlementsDidChange: { value in
                await publications.append(UInt64(value.transactions.count))
                await published.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected background failure: \(failure)")
            }
        )

        _ = try await session.start()
        await values.replace(with: [])

        fixture.subscriptionStatusUpdates.yield()
        try await published.wait(for: 2)

        #expect(await handlerCalls.value() == 0)
        #expect(await fixture.entitlementQueryCount.value() == 2)
        #expect(await publications.snapshot() == [1, 0])
        try await session.close()
    }

    @Test("a new subscription status is handled and finished before publication")
    func newSubscriptionStatusUsesTransactionPipeline() async throws {
        let snapshot = makeSnapshot(id: 2, productID: "subscription.pro")
        let values = EntitlementValueSource([])
        let unfinished = UnfinishedValueSource()
        let fixture = TestSourceFixture(
            currentEntitlements: { await values.read() },
            queryUnfinished: { await unfinished.read() }
        )
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let events = StringRecorder()
        let publications = UInt64Recorder()
        let published = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { snapshot in
                await events.append("handle-\(snapshot.id)")
                await handlerStarted.send()
                try await handlerGate.wait()
            },
            entitlementsDidChange: { value in
                await publications.append(UInt64(value.transactions.count))
                await published.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected background failure: \(failure)")
            }
        )

        _ = try await session.start()
        await values.replace(with: [snapshot])
        await unfinished.replace(
            with: [
                .verified(
                    makeEnvelope(snapshot: snapshot) {
                        await events.append("finish-2")
                    })
            ]
        )
        fixture.subscriptionStatusUpdates.yield()

        try await handlerStarted.wait(for: 1)
        #expect(await publications.snapshot() == [0])
        #expect(await fixture.entitlementQueryCount.value() == 2)

        await handlerGate.open()
        try await published.wait(for: 2)
        #expect(await events.snapshot() == ["handle-2", "finish-2"])
        #expect(await fixture.entitlementQueryCount.value() == 3)
        #expect(await publications.snapshot() == [0, 1])
        try await session.close()
    }

    @Test("an unfinished consumable failure blocks publication and reports once")
    func unfinishedConsumableFailureBlocksPublication() async throws {
        let active = makeSnapshot(
            id: 3,
            productID: "subscription.plus",
            productType: .autoRenewable
        )
        let consumable = makeSnapshot(
            id: 4,
            productID: "consumable.tokens",
            productType: .consumable
        )
        let values = EntitlementValueSource([active])
        let unfinished = UnfinishedValueSource()
        let fixture = TestSourceFixture(
            currentEntitlements: { await values.read() },
            queryUnfinished: { await unfinished.read() }
        )
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let publications = UInt64Recorder()
        let published = TestSignal()
        let reports = StringRecorder()
        let reported = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { snapshot in
                #expect(snapshot.id == consumable.id)
                await handlerCalls.send()
                if await handlerCalls.value() == 1 {
                    throw TestFailure()
                }
            },
            entitlementsDidChange: { value in
                await publications.append(UInt64(value.transactions.count))
                await published.send()
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    failure.transactionID == consumable.id,
                    failure.productID == consumable.productID,
                    failure.underlyingError is TestFailure
                {
                    await reports.append("unfinished-4")
                } else {
                    await reports.append("unexpected")
                }
                await reported.send()
            }
        )

        _ = try await session.start()
        await values.replace(with: [])
        await unfinished.replace(
            with: [
                .verified(
                    makeEnvelope(snapshot: consumable) {
                        await finishes.send()
                        await unfinished.replace(with: [])
                    })
            ]
        )

        fixture.subscriptionStatusUpdates.yield()
        try await reported.wait(for: 1)

        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 0)
        #expect(await publications.snapshot() == [1])

        fixture.subscriptionStatusUpdates.yield()
        try await published.wait(for: 2)

        #expect(await handlerCalls.value() == 2)
        #expect(await finishes.value() == 1)
        #expect(await publications.snapshot() == [1, 0])
        #expect(await reports.snapshot() == ["unfinished-4"])
        try await session.close()
    }

    @Test("revocation handling finishes before entitlement removal is published")
    func revocationPrecedesRemovalPublication() async throws {
        let active = makeSnapshot(
            id: 31,
            productID: "subscription.plus",
            productType: .autoRenewable,
            jws: "active-31"
        )
        let revoked = makeSnapshot(
            id: 31,
            productID: "subscription.plus",
            productType: .autoRenewable,
            signedDate: Date(timeIntervalSince1970: 100),
            jws: "revoked-31",
            revocationDate: Date(timeIntervalSince1970: 99)
        )
        let values = EntitlementValueSource([active])
        let unfinished = UnfinishedValueSource()
        let fixture = TestSourceFixture(
            currentEntitlements: { await values.read() },
            queryUnfinished: { await unfinished.read() }
        )
        let handlerStarted = TestSignal()
        let handlerGate = TestGate()
        let events = StringRecorder()
        let publications = UInt64Recorder()
        let published = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { snapshot in
                #expect(snapshot.revocationDate != nil)
                await events.append("handle-\(snapshot.id)")
                await handlerStarted.send()
                try await handlerGate.wait()
            },
            entitlementsDidChange: { value in
                await publications.append(UInt64(value.transactions.count))
                await published.send()
            },
            reportFailure: { failure in
                Issue.record("Unexpected revocation failure: \(failure)")
            }
        )

        _ = try await session.start()
        await values.replace(with: [])
        await unfinished.replace(
            with: [
                .verified(
                    makeEnvelope(snapshot: revoked) {
                        await events.append("finish-31")
                    })
            ]
        )
        fixture.subscriptionStatusUpdates.yield()

        try await handlerStarted.wait(for: 1)
        #expect(await publications.snapshot() == [1])

        await handlerGate.open()
        try await published.wait(for: 2)
        #expect(await events.snapshot() == ["handle-31", "finish-31"])
        #expect(await publications.snapshot() == [1, 0])
        try await session.close()
    }

    @Test("reconciliation drains and reports every accepted handler failure")
    func reconciliationDrainsAllAcceptedFailures() async throws {
        let unfinished = UnfinishedValueSource([
            .verified(
                makeEnvelope(
                    snapshot: makeSnapshot(
                        id: 32,
                        productID: "subscription.plus",
                        productType: .autoRenewable
                    )
                )
            ),
            .verified(
                makeEnvelope(
                    snapshot: makeSnapshot(
                        id: 33,
                        productID: "lifetime",
                        productType: .nonConsumable
                    )
                )
            ),
        ])
        let fixture = TestSourceFixture(
            queryUnfinished: { await unfinished.read() }
        )
        let handlerCalls = TestSignal()
        let reports = UInt64Recorder()
        let reported = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                await handlerCalls.send()
                throw TestFailure()
            },
            reportFailure: { failure in
                if failure.source == .unfinished,
                    let transactionID = failure.transactionID
                {
                    await reports.append(transactionID)
                    await reported.send()
                }
            }
        )

        await #expect(throws: TestFailure.self) {
            _ = try await session.start()
        }
        try await reported.wait(for: 2)

        #expect(await handlerCalls.value() == 2)
        #expect(await reports.snapshot() == [32, 33])
        try await session.close()
    }

    @Test("unverified current elements are reported without hiding verified entitlements")
    func mixedCurrentEntitlementVerification() async throws {
        let snapshot = makeSnapshot(id: 5, productID: "subscription.plus")
        let verificationFailure = StoreTransactionVerificationError(
            underlyingError: TestFailure()
        )
        let fixture = TestSourceFixture(
            currentEntitlements: { [snapshot] },
            currentEntitlementVerificationFailures: {
                [verificationFailure]
            }
        )
        let reported = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                if case .currentEntitlementVerification = failure.source {
                    await reported.send()
                }
            }
        )

        let readiness = try await session.start()

        #expect(readiness.entitlements.transactions == [snapshot])
        try await reported.wait(for: 1)
        try await session.close()
    }

    @Test("updates use the durable handler then finish and refresh")
    func updateProcessing() async throws {
        let fixture = TestSourceFixture()
        let events = StringRecorder()
        let finished = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { snapshot in
                await events.append("handle-\(snapshot.id)")
            },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                Issue.record("Unexpected background failure: \(failure)")
            }
        )
        _ = try await session.start()

        let snapshot = makeSnapshot(id: 10)
        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: snapshot) {
                    await events.append("finish-10")
                    await finished.send()
                }))
        try await finished.wait(for: 1)

        #expect(await events.snapshot() == ["handle-10", "finish-10"])
        try await fixture.entitlementQueryCount.wait(for: 2)
        try await session.close()
    }

    @Test("background handler failures are reported and never finished")
    func backgroundFailure() async throws {
        let fixture = TestSourceFixture()
        let reported = TestSignal()
        let finished = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in throw TestFailure() },
            entitlementsDidChange: { _ in },
            reportFailure: { failure in
                if failure.transactionID == 11 {
                    await reported.send()
                }
            }
        )
        _ = try await session.start()
        fixture.updates.yield(
            .verified(
                makeEnvelope(
                    snapshot: makeSnapshot(id: 11)
                ) {
                    await finished.send()
                }))

        try await reported.wait(for: 1)
        #expect(await finished.value() == 0)
        try await session.close()
    }

    @Test("close before start is idempotent and later operations are rejected")
    func closeBeforeStart() async throws {
        let fixture = TestSourceFixture()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )

        try await session.close()
        try await session.close()
        await #expect(throws: StoreTransactionError.self) {
            _ = try await session.start()
        }
    }

    @Test("callbacks reject reentry into their own session")
    func callbackReentrancy() async throws {
        let fixture = TestSourceFixture()
        let holder = SessionHolder()
        let observations = StringRecorder()
        let finished = TestSignal()
        let failureReported = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in
                do {
                    try await holder.get().close()
                    await observations.append("handler-unexpected-success")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .close
                ) {
                    await observations.append("handler-rejected")
                } catch {
                    Issue.record("Unexpected handler reentrancy error: \(error)")
                }
            },
            entitlementsDidChange: { _ in
                do {
                    _ = try await holder.get().currentEntitlements()
                    await observations.append("entitlements-unexpected-success")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .currentEntitlements
                ) {
                    await observations.append("entitlements-rejected")
                } catch {
                    Issue.record("Unexpected entitlement reentrancy error: \(error)")
                }
            },
            reportFailure: { _ in
                do {
                    _ = try await holder.get().history(for: "product")
                    await observations.append("reporter-unexpected-success")
                } catch StoreTransactionError.reentrantOperation(
                    operation: .history
                ) {
                    await observations.append("reporter-rejected")
                } catch {
                    Issue.record("Unexpected reporter reentrancy error: \(error)")
                }
                await failureReported.send()
            }
        )
        holder.set(session)

        _ = try await session.start()
        fixture.updates.yield(
            .verified(
                makeEnvelope(snapshot: makeSnapshot(id: 12)) {
                    await finished.send()
                }))
        try await finished.wait(for: 1)
        fixture.updates.yield(.unverified(TestFailure()))
        try await failureReported.wait(for: 1)

        #expect(
            await observations.snapshot() == [
                "entitlements-rejected",
                "handler-rejected",
                "reporter-rejected",
            ])
        try await session.close()
    }

    @Test("a callback may operate on a different session")
    func callbackMayUseAnotherSession() async throws {
        let otherFixture = TestSourceFixture()
        let otherSession = StoreTransactionSession(
            source: otherFixture.source,
            handleTransaction: { _ in },
            reportFailure: { _ in }
        )
        let fixture = TestSourceFixture()
        let callbackCompleted = TestSignal()
        let session = StoreTransactionSession(
            source: fixture.source,
            handleTransaction: { _ in },
            entitlementsDidChange: { _ in
                do {
                    try await otherSession.close()
                    await callbackCompleted.send()
                } catch {
                    Issue.record("A different session rejected the callback: \(error)")
                }
            },
            reportFailure: { _ in }
        )

        _ = try await session.start()
        try await callbackCompleted.wait(for: 1)
        try await session.close()
    }
}
