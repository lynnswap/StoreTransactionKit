import Testing
@testable import StoreTransactionKit

@Suite("EntitlementRefreshCoordinator")
struct EntitlementRefreshCoordinatorTests {
    @Test("reservations that arrive during a query run in the next cycle")
    func cutoffReservations() async throws {
        let query = ControlledEntitlementQuery()
        let publicationSizes = UInt64Recorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { try await query.next() },
            didChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            }
        )

        let first = await coordinator.reserve()
        await query.waitForRequest(1)
        let second = await coordinator.reserve()
        await query.succeed([makeSnapshot(id: 1, productID: "b")])

        let firstValue = try await first.terminalValue()
        #expect(firstValue.transactions.map(\.productID) == ["b"])
        await query.waitForRequest(2)
        await query.succeed([
            makeSnapshot(id: 2, productID: "a"),
            makeSnapshot(id: 1, productID: "b"),
        ])
        let secondValue = try await second.terminalValue()

        #expect(secondValue.transactions.map(\.productID) == ["a", "b"])
        #expect(await publicationSizes.snapshot() == [1, 2])
        await coordinator.sealAndDrain()
    }

    @Test("equal content completes reservations without a new publication")
    func equalContentDoesNotPublish() async throws {
        let query = ControlledEntitlementQuery()
        let publicationSizes = UInt64Recorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { try await query.next() },
            didChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            }
        )
        let snapshot = makeSnapshot(id: 4)

        let first = await coordinator.reserve()
        await query.waitForRequest(1)
        await query.succeed([snapshot])
        _ = try await first.terminalValue()

        let second = await coordinator.reserve()
        await query.waitForRequest(2)
        await query.succeed([snapshot])
        let value = try await second.terminalValue()

        #expect(value.transactions == [snapshot])
        #expect(await publicationSizes.snapshot() == [1])
        await coordinator.sealAndDrain()
    }

    @Test("an unverified or failed query never publishes a partial replacement")
    func failedQueryDoesNotPublish() async throws {
        let query = ControlledEntitlementQuery()
        let publicationSizes = UInt64Recorder()
        let coordinator = EntitlementRefreshCoordinator(
            query: { try await query.next() },
            didChange: { value in
                await publicationSizes.append(UInt64(value.transactions.count))
            }
        )

        let failed = await coordinator.reserve()
        await query.waitForRequest(1)
        await query.fail(TestFailure())
        await #expect(throws: TestFailure.self) {
            _ = try await failed.terminalValue()
        }
        #expect(await publicationSizes.snapshot().isEmpty)

        let recovered = await coordinator.reserve()
        await query.waitForRequest(2)
        await query.succeed([])
        let value = try await recovered.terminalValue()
        #expect(value.transactions.isEmpty)
        #expect(await publicationSizes.snapshot() == [0])
        await coordinator.sealAndDrain()
    }
}
