import Foundation
import Testing
@testable import StoreTransactionKit

@Suite("EntitlementRefreshCoordinator", .timeLimit(.minutes(1)))
struct EntitlementRefreshCoordinatorTests {
    @Test("a reservation after the physical query cutoff starts a later query")
    func physicalQueryCutoff() async throws {
        let query = ControlledReconciliationQuery()
        let failures = FailureReporterDispatcher()
        let coordinator = makeCoordinator(query: query, failures: failures)

        let first = await coordinator.reserve()
        try await query.waitForRequest(1)
        let second = await coordinator.reserve()

        #expect(first.role == .owner)
        #expect(second.role == .owner)
        await query.succeed([])
        _ = try await first.receipt.terminalValue()

        try await query.waitForRequest(2)
        await query.succeed([])
        _ = try await second.receipt.terminalValue()

        await coordinator.sealAndDrain()
        await failures.sealAndDrain()
    }

    @Test("publication callback completes before the reservation receipt")
    func publicationPrecedesReceipt() async throws {
        let query = ControlledReconciliationQuery()
        let failures = FailureReporterDispatcher()
        let callbackStarted = TestSignal()
        let callbackGate = TestGate()
        let receiptCompleted = TestSignal()
        let coordinator = EntitlementRefreshCoordinator<TestEntitlement>(
            query: { _ in try await query.next() },
            project: {
                (_: StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
                    -> Set<TestEntitlement> in
                [.tier1]
            },
            didComplete: { _ in
                await callbackStarted.send()
                try? await callbackGate.wait()
            },
            failures: failures
        )

        let reservation = await coordinator.reserve()
        try await query.waitForRequest(1)
        await query.succeed([])
        let waiter = Task {
            _ = try await reservation.receipt.terminalValue()
            await receiptCompleted.send()
        }
        try await callbackStarted.wait(for: 1)
        #expect(await receiptCompleted.value() == 0)

        await callbackGate.open()
        try await waiter.value
        #expect(await receiptCompleted.value() == 1)

        await coordinator.sealAndDrain()
        await failures.sealAndDrain()
    }

    @Test("catalog projection failure is classified at the projection boundary")
    func catalogFailureClassification() async throws {
        let query = ControlledReconciliationQuery()
        let failures = FailureReporterDispatcher()
        let outcomes = RefreshOutcomeRecorder()
        let catalogError = AutoRenewableSubscriptionCatalogError.undeclaredProduct(
            productID: "undeclared",
            subscriptionGroupID: TestPlans.id
        )
        let coordinator = EntitlementRefreshCoordinator<TestEntitlement>(
            query: { _ in try await query.next() },
            project: {
                (_: StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
                    -> Set<TestEntitlement> in
                throw catalogError
            },
            didComplete: { outcome in await outcomes.append(outcome) },
            failures: failures
        )

        let reservation = await coordinator.reserve()
        try await query.waitForRequest(1)
        await query.succeed([])
        await #expect(throws: AutoRenewableSubscriptionCatalogError.self) {
            _ = try await reservation.receipt.terminalValue()
        }

        #expect(await outcomes.kinds() == [.catalogFailure])
        await coordinator.sealAndDrain()
        await failures.sealAndDrain()
    }

    private func makeCoordinator(
        query: ControlledReconciliationQuery,
        failures: FailureReporterDispatcher
    ) -> EntitlementRefreshCoordinator<TestEntitlement> {
        EntitlementRefreshCoordinator(
            query: { _ in try await query.next() },
            project: {
                (_: StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
                    -> Set<TestEntitlement> in
                []
            },
            didComplete: { _ in },
            failures: failures
        )
    }
}

private actor ControlledReconciliationQuery {
    private struct Request {
        let id: UUID
        let continuation: CheckedContinuation<CurrentEntitlementReconciliation, any Error>
    }

    private var requests: [Request] = []
    private let started = TestSignal()

    func next() async throws -> CurrentEntitlementReconciliation {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(id: id, continuation: continuation))
                Task { await started.send() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForRequest(_ count: Int) async throws {
        try await started.wait(for: count)
    }

    func succeed(_ snapshots: [StoreTransactionSnapshot]) {
        precondition(!requests.isEmpty)
        requests.removeFirst().continuation.resume(
            returning: CurrentEntitlementReconciliation(
                snapshots: snapshots,
                causalClaims: [],
                diagnostics: []
            )
        )
    }

    private func cancel(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else {
            return
        }
        requests.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }
}

private actor RefreshOutcomeRecorder {
    enum Kind: Equatable, Sendable {
        case success
        case transientFailure
        case catalogFailure
    }

    private var values: [Kind] = []

    func append(_ outcome: EntitlementRefreshOutcome<TestEntitlement>) {
        switch outcome {
        case .success:
            values.append(.success)
        case .transientFailure:
            values.append(.transientFailure)
        case .catalogFailure:
            values.append(.catalogFailure)
        }
    }

    func kinds() -> [Kind] {
        values
    }
}
