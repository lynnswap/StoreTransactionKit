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

final class TestCounterSignal: Sendable {
    private struct Waiter: Sendable {
        let target: Int
        let receipt: ProcessingReceipt<Void>
    }

    private struct State: Sendable {
        var count = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    func send() {
        let ready = state.withLock { state -> [ProcessingReceipt<Void>] in
            state.count += 1
            var ready: [ProcessingReceipt<Void>] = []
            state.waiters.removeAll { waiter in
                guard waiter.target <= state.count else { return false }
                ready.append(waiter.receipt)
                return true
            }
            return ready
        }
        for receipt in ready {
            receipt.succeed(())
        }
    }

    func wait(for target: Int) async throws {
        precondition(target > 0)
        let receipt = state.withLock {
            state -> ProcessingReceipt<Void>? in
            guard state.count < target else { return nil }
            let receipt = ProcessingReceipt<Void>()
            state.waiters.append(Waiter(target: target, receipt: receipt))
            return receipt
        }
        guard let receipt else { return }
        do {
            try await receipt.value()
        } catch is ProcessingReceiptWaiterCancellation {
            throw CancellationError()
        }
    }

    func value() -> Int {
        state.withLock(\.count)
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

final class TransactionStoreHolder<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    private let storage = Mutex<TransactionStore<Entitlement>?>(nil)

    func set(_ store: TransactionStore<Entitlement>) {
        storage.withLock { value in
            precondition(value == nil)
            value = store
        }
    }

    func get() -> TransactionStore<Entitlement> {
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
    private let cancelled = TestSignal()

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

    func waitForCancellation(_ count: Int = 1) async throws {
        try await cancelled.wait(for: count)
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
        Task { await cancelled.send() }
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
    subscriptionGroupID: String? = nil,
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
        subscriptionGroupID: subscriptionGroupID,
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

enum TestEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

enum TestPlans: AutoRenewableSubscriptionGroup<TestEntitlement> {
    static let id = SubscriptionGroupID(rawValue: "test.subscription.group")

    enum ProductID: String, Hashable, Sendable {
        case tier1Monthly = "test.subscription.tier1.monthly"
        case tier1Yearly = "test.subscription.tier1.yearly"
        case tier2Monthly = "test.subscription.tier2.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.tier1Monthly, entitlement: .tier1)
        StoreSubscription(.tier1Yearly, entitlement: .tier1)
        StoreSubscription(.tier2Monthly, entitlement: .tier2)
    }
}

let testSubscriptionCatalog: AutoRenewableSubscriptionCatalog<TestEntitlement> =
    AutoRenewableSubscriptionCatalog(TestPlans.self)

func makeSubscriptionSnapshot(
    id: UInt64,
    productID: TestPlans.ProductID,
    isUpgraded: Bool = false,
    revision: String? = nil
) -> StoreTransactionSnapshot {
    makeSnapshot(
        id: id,
        productID: productID.rawValue,
        productType: .autoRenewable,
        subscriptionGroupID: TestPlans.id.rawValue,
        jws: revision,
        isUpgraded: isUpgraded
    )
}

struct TestSourceFixture: Sendable {
    let source: StoreTransactionSource
    let updates: AsyncStream<StoreTransactionDelivery>.Continuation
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
        self.subscriptionStatusUpdates = subscriptionStatusPair.continuation
        self.updateTermination = updateTermination
        self.subscriptionStatusDeliveryCount = subscriptionStatusDeliveryCount
        self.subscriptionStatusTermination = subscriptionStatusTermination
        self.entitlementQueryCount = entitlementQueryCount
        self.source = StoreTransactionSource(
            runUpdates: { beginIteration, consume in
                var iterator = updatePair.stream.makeAsyncIterator()
                while let lease = beginIteration() {
                    defer { lease.end() }
                    guard let delivery = await iterator.next() else { return }
                    await consume(delivery)
                }
            },
            runSubscriptionStatusUpdates: { beginIteration, consume in
                var iterator = subscriptionStatusPair.stream.makeAsyncIterator()
                while let lease = beginIteration() {
                    defer { lease.end() }
                    guard await iterator.next() != nil else { return }
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
