import Testing
@testable import StoreTransactionKit

@Suite("Completed delivery entitlement refresh", .timeLimit(.minutes(1)))
struct CompletedDeliveryRefreshTests {
    @Test("a completed redelivery retries a failed entitlement refresh")
    func completedRedeliveryRetriesRefresh() async {
        let snapshot = makeSnapshot(
            id: 51,
            productID: "lifetime.completed",
            productType: .nonConsumable,
            jws: "completed-redelivery"
        )
        let query = FailingOnceEntitlementQuery(recovered: [snapshot])
        let handlerCalls = TestSignal()
        let finishes = TestSignal()
        let publications = UInt64Recorder()
        let reports = StringRecorder()
        let core = TransactionProcessingCore<StoreTransactionSnapshot> { _ in
            await handlerCalls.send()
        }
        let entitlements = EntitlementRefreshCoordinator(
            query: { try await query.next() },
            didChange: { value in
                await publications.append(UInt64(value.transactions.count))
            }
        )
        let failures = FailureReporterDispatcher { failure in
            await reports.append(
                "\(failure.source)-\(failure.transactionID ?? 0)-\(failure.productID ?? "")"
            )
        }
        let pipeline = StoreTransactionPipeline(
            core: core,
            entitlements: entitlements,
            failures: failures
        )
        let delivery = StoreTransactionDelivery.verified(
            makeEnvelope(snapshot: snapshot) {
                await finishes.send()
            }
        )

        await pipeline.processBackground(delivery, source: .updates)
        await pipeline.processBackground(delivery, source: .unfinished)

        await core.finishInputAndDrain()
        await entitlements.sealAndDrain()
        await failures.sealAndDrain()
        #expect(await query.count() == 2)
        #expect(await handlerCalls.value() == 1)
        #expect(await finishes.value() == 1)
        #expect(await publications.snapshot() == [1])
        #expect(
            await reports.snapshot() == [
                "entitlementRefresh-51-lifetime.completed"
            ]
        )
    }
}

private actor FailingOnceEntitlementQuery {
    private let recovered: [StoreTransactionSnapshot]
    private var invocationCount = 0

    init(recovered: [StoreTransactionSnapshot]) {
        self.recovered = recovered
    }

    func next() throws -> [StoreTransactionSnapshot] {
        invocationCount += 1
        if invocationCount == 1 {
            throw TestFailure()
        }
        return recovered
    }

    func count() -> Int {
        invocationCount
    }
}
