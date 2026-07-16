import Foundation
import StoreKit
import Synchronization
import Testing
@testable import StoreTransactionKit

actor TestSignal {
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func send() {
        count += 1
        let ready = waiters.compactMap { id, waiter in
            waiter.target <= count ? id : nil
        }
        for id in ready {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func wait(for target: Int) async throws {
        guard count < target else { return }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= target {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(
                        target: target,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func value() -> Int {
        count
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

actor TestGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        guard !isOpen else { return }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func open() {
        isOpen = true
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }
}

actor StringRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

actor UInt64Recorder {
    private var values: [UInt64] = []

    func append(_ value: UInt64) {
        values.append(value)
    }

    func snapshot() -> [UInt64] {
        values
    }
}

final class SessionHolder: Sendable {
    private let storage = Mutex<StoreTransactionSession?>(nil)

    func set(_ session: StoreTransactionSession) {
        storage.withLock { value in
            precondition(value == nil)
            value = session
        }
    }

    func get() -> StoreTransactionSession {
        storage.withLock { value in
            guard let value else {
                preconditionFailure("SessionHolder was read before initialization.")
            }
            return value
        }
    }
}

final class TransactionStoreHolder<EntitlementID>: Sendable
where
    EntitlementID: RawRepresentable & Hashable & Sendable,
    EntitlementID.RawValue == String
{
    private let storage = Mutex<TransactionStore<EntitlementID>?>(nil)

    func set(_ store: TransactionStore<EntitlementID>) {
        storage.withLock { value in
            precondition(value == nil)
            value = store
        }
    }

    func get() -> TransactionStore<EntitlementID> {
        storage.withLock { value in
            guard let value else {
                preconditionFailure("TransactionStoreHolder was read before initialization.")
            }
            return value
        }
    }
}

actor ControlledEntitlementQuery {
    private struct Request {
        let id: UUID
        let continuation: CheckedContinuation<[StoreTransactionSnapshot], any Error>
    }

    private var requests: [Request] = []
    private let started = TestSignal()

    func next() async throws -> [StoreTransactionSnapshot] {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(id: id, continuation: continuation))
                Task { await started.send() }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func waitForRequest(_ count: Int) async throws {
        try await started.wait(for: count)
    }

    func succeed(_ snapshots: [StoreTransactionSnapshot]) {
        precondition(!requests.isEmpty)
        requests.removeFirst().continuation.resume(returning: snapshots)
    }

    func fail(_ error: any Error) {
        precondition(!requests.isEmpty)
        requests.removeFirst().continuation.resume(throwing: error)
    }

    private func cancelRequest(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else {
            return
        }
        requests.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }
}

actor EntitlementValueSource {
    private var value: [StoreTransactionSnapshot]

    init(_ value: [StoreTransactionSnapshot]) {
        self.value = value
    }

    func read() -> [StoreTransactionSnapshot] {
        value
    }

    func replace(with value: [StoreTransactionSnapshot]) {
        self.value = value
    }
}

actor UnfinishedValueSource {
    private var value: [StoreTransactionDelivery]

    init(_ value: [StoreTransactionDelivery] = []) {
        self.value = value
    }

    func read() -> [StoreTransactionDelivery] {
        value
    }

    func replace(with value: [StoreTransactionDelivery]) {
        self.value = value
    }
}

func makeSnapshot(
    id: UInt64,
    productID: String = "product",
    productType: Product.ProductType = .consumable,
    purchaseDate: Date? = nil,
    signedDate: Date? = nil,
    jws: String? = nil,
    revocationDate: Date? = nil,
    isUpgraded: Bool = false
) -> StoreTransactionSnapshot {
    let purchaseDate = purchaseDate ?? Date(timeIntervalSince1970: TimeInterval(id))
    return StoreTransactionSnapshot(
        id: id,
        originalID: id,
        productID: productID,
        subscriptionGroupID: nil,
        productType: productType,
        environment: .xcode,
        offer: nil,
        storefrontID: "143441",
        storefrontCountryCode: "USA",
        price: nil,
        currency: nil,
        purchaseDate: purchaseDate,
        originalPurchaseDate: purchaseDate,
        expirationDate: nil,
        revocationDate: revocationDate,
        revocationReason: nil,
        purchasedQuantity: 1,
        isUpgraded: isUpgraded,
        ownershipType: .purchased,
        reason: .purchase,
        appAccountToken: nil,
        signedDate: signedDate ?? purchaseDate,
        jwsRepresentation: jws ?? "jws-\(id)"
    )
}

func makeEnvelope(
    snapshot: StoreTransactionSnapshot,
    revision: String? = nil,
    finish: @escaping @Sendable () async -> Void = {}
) -> ProcessingEnvelope<StoreTransactionSnapshot> {
    ProcessingEnvelope(
        revision: Data((revision ?? snapshot.jwsRepresentation).utf8),
        value: snapshot,
        finish: finish
    )
}

struct TestFailure: Error, Sendable, Equatable {}

struct TestSourceFixture: Sendable {
    let source: StoreTransactionSource
    let updates: AsyncStream<StoreTransactionDelivery>.Continuation
    let unfinished: AsyncStream<StoreTransactionDelivery>.Continuation
    let subscriptionStatusUpdates: AsyncStream<Void>.Continuation
    let updateTermination: TestSignal
    let subscriptionStatusDeliveryCount: TestSignal
    let subscriptionStatusTermination: TestSignal
    let entitlementQueryCount: TestSignal

    init(
        currentEntitlements:
            @escaping @Sendable () async throws
            -> [StoreTransactionSnapshot] = { [] },
        currentEntitlementVerificationFailures:
            @escaping @Sendable () async
            -> [StoreTransactionVerificationError] = { [] },
        queryUnfinished:
            @escaping @Sendable () async
            -> [StoreTransactionDelivery] = { [] },
        history:
            @escaping @Sendable (Product.ID) async throws
            -> [StoreTransactionSnapshot] = { _ in [] },
        synchronize: @escaping @Sendable () async throws -> Void = {}
    ) {
        let updatePair = AsyncStream<StoreTransactionDelivery>.makeStream()
        let unfinishedPair = AsyncStream<StoreTransactionDelivery>.makeStream()
        let subscriptionStatusPair = AsyncStream<Void>.makeStream()
        let updateTermination = TestSignal()
        let subscriptionStatusDeliveryCount = TestSignal()
        let subscriptionStatusTermination = TestSignal()
        let entitlementQueryCount = TestSignal()
        updatePair.continuation.onTermination = { _ in
            Task { await updateTermination.send() }
        }
        subscriptionStatusPair.continuation.onTermination = { _ in
            Task { await subscriptionStatusTermination.send() }
        }
        self.updates = updatePair.continuation
        self.unfinished = unfinishedPair.continuation
        self.subscriptionStatusUpdates = subscriptionStatusPair.continuation
        self.updateTermination = updateTermination
        self.subscriptionStatusDeliveryCount = subscriptionStatusDeliveryCount
        self.subscriptionStatusTermination = subscriptionStatusTermination
        self.entitlementQueryCount = entitlementQueryCount
        self.source = StoreTransactionSource(
            runUpdates: { consume in
                for await delivery in updatePair.stream {
                    await consume(delivery)
                }
            },
            runUnfinished: { consume in
                for await delivery in unfinishedPair.stream {
                    await consume(delivery)
                }
            },
            runSubscriptionStatusUpdates: { consume in
                for await _ in subscriptionStatusPair.stream {
                    await subscriptionStatusDeliveryCount.send()
                    await consume()
                }
            },
            currentEntitlements: {
                await entitlementQueryCount.send()
                return CurrentEntitlementQueryResult(
                    snapshots: try await currentEntitlements(),
                    verificationFailures:
                        await currentEntitlementVerificationFailures()
                )
            },
            queryUnfinished: queryUnfinished,
            history: history,
            synchronize: synchronize,
            purchaseDelivery: { result in
                LiveTransactionAdapter.delivery(result)
            }
        )
    }
}
