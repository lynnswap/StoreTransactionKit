import Testing
@testable import StoreTransactionKit

@Suite("EntitlementRefreshCoordinator", .timeLimit(.minutes(1)))
struct EntitlementRefreshCoordinatorTests {
    @Test("reservations that arrive during a query run in the next cycle")
    func cutoffReservations() async throws {
        let query = ControlledEntitlementQuery()
        let publicationSizes = UInt64Recorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { _ in try await query.next() },
            didChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            }
        )

        let first = await coordinator.reserve()
        try await query.waitForRequest(1)
        let second = await coordinator.reserve()
        await query.succeed([makeSnapshot(id: 1, productID: "b")])

        let firstValue = try await first.receipt.terminalValue()
        #expect(firstValue.transactions.map(\.productID) == ["b"])
        try await query.waitForRequest(2)
        await query.succeed([
            makeSnapshot(id: 2, productID: "a"),
            makeSnapshot(id: 1, productID: "b"),
        ])
        let secondValue = try await second.receipt.terminalValue()

        #expect(secondValue.transactions.map(\.productID) == ["a", "b"])
        #expect(await publicationSizes.snapshot() == [1, 2])
        await coordinator.sealAndDrain()
    }

    @Test("equal content completes reservations without a new publication")
    func equalContentDoesNotPublish() async throws {
        let query = ControlledEntitlementQuery()
        let publicationSizes = UInt64Recorder()
        let successfulTokens = UInt64Recorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { _ in try await query.next() },
            didChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            },
            didSucceed: { success in
                await successfulTokens.append(success.token)
            }
        )
        let snapshot = makeSnapshot(id: 4)

        let first = await coordinator.reserve()
        try await query.waitForRequest(1)
        await query.succeed([snapshot])
        _ = try await first.receipt.terminalValue()

        let second = await coordinator.reserve()
        try await query.waitForRequest(2)
        await query.succeed([snapshot])
        let value = try await second.receipt.terminalValue()

        #expect(value.transactions == [snapshot])
        #expect(await publicationSizes.snapshot() == [1])
        #expect(await successfulTokens.snapshot() == [1, 2])
        await coordinator.sealAndDrain()
    }

    @Test("an unverified or failed query never publishes a partial replacement")
    func failedQueryDoesNotPublish() async throws {
        let query = ControlledEntitlementQuery()
        let publicationSizes = UInt64Recorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { _ in try await query.next() },
            didChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            }
        )

        let failed = await coordinator.reserve()
        try await query.waitForRequest(1)
        await query.fail(TestFailure())
        await #expect(throws: TestFailure.self) {
            _ = try await failed.receipt.terminalValue()
        }
        #expect(await publicationSizes.snapshot().isEmpty)

        let recovered = await coordinator.reserve()
        try await query.waitForRequest(2)
        await query.succeed([])
        let value = try await recovered.receipt.terminalValue()
        #expect(value.transactions.isEmpty)
        #expect(await publicationSizes.snapshot() == [0])
        await coordinator.sealAndDrain()
    }

    @Test("each pending query batch has one reporting owner")
    func pendingBatchReportingAuthority() async throws {
        let query = ControlledEntitlementQuery()
        let coordinator = EntitlementRefreshCoordinator(
            query: { _ in try await query.next() },
            didChange: { _ in }
        )

        let active = await coordinator.reserve()
        try await query.waitForRequest(1)
        let nextOwner = await coordinator.reserve()
        let nextObserver = await coordinator.reserve()

        #expect(active.role == .owner)
        #expect(nextOwner.role == .owner)
        #expect(nextObserver.role == .observer)

        await query.succeed([])
        _ = try await active.receipt.terminalValue()
        try await query.waitForRequest(2)
        await query.succeed([])
        _ = try await nextOwner.receipt.terminalValue()
        _ = try await nextObserver.receipt.terminalValue()
        await coordinator.sealAndDrain()
    }

    @Test("mixed retry policies form contiguous query batches")
    func mixedRetryPolicyBatches() async throws {
        let query = ControlledEntitlementQuery()
        let policies = StringRecorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { retryFailedTransactions in
                await policies.append(String(retryFailedTransactions))
                return try await query.next()
            },
            didChange: { _ in }
        )

        let active = await coordinator.reserve(
            retryFailedTransactions: false
        )
        try await query.waitForRequest(1)
        let falseOwner = await coordinator.reserve(
            retryFailedTransactions: false
        )
        let falseObserver = await coordinator.reserve(
            retryFailedTransactions: false
        )
        let trueOwner = await coordinator.reserve(
            retryFailedTransactions: true
        )
        let trueObserver = await coordinator.reserve(
            retryFailedTransactions: true
        )
        let trailingFalseOwner = await coordinator.reserve(
            retryFailedTransactions: false
        )

        #expect(falseOwner.role == .owner)
        #expect(falseObserver.role == .observer)
        #expect(trueOwner.role == .owner)
        #expect(trueObserver.role == .observer)
        #expect(trailingFalseOwner.role == .owner)

        await query.succeed([])
        _ = try await active.receipt.terminalValue()

        try await query.waitForRequest(2)
        await query.succeed([])
        _ = try await falseOwner.receipt.terminalValue()
        _ = try await falseObserver.receipt.terminalValue()

        try await query.waitForRequest(3)
        await query.succeed([])
        _ = try await trueOwner.receipt.terminalValue()
        _ = try await trueObserver.receipt.terminalValue()

        try await query.waitForRequest(4)
        await query.succeed([])
        _ = try await trailingFalseOwner.receipt.terminalValue()

        #expect(
            await policies.snapshot() == [
                "false", "false", "true", "false",
            ])
        await coordinator.sealAndDrain()
    }
}
