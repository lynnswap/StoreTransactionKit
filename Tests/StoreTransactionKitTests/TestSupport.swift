import Foundation
import StoreKit
import Synchronization
import Testing
@testable import StoreTransactionKit

actor TestSignal {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func send() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(for target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    func value() -> Int {
        count
    }
}

actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
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

final class StoreHolder<EntitlementID>: Sendable
where
    EntitlementID: RawRepresentable & Hashable & Sendable,
    EntitlementID.RawValue == String
{
    private let storage = Mutex<Store<EntitlementID>?>(nil)

    func set(_ store: Store<EntitlementID>) {
        storage.withLock { value in
            precondition(value == nil)
            value = store
        }
    }

    func get() -> Store<EntitlementID> {
        storage.withLock { value in
            guard let value else {
                preconditionFailure("StoreHolder was read before initialization.")
            }
            return value
        }
    }
}

actor ControlledEntitlementQuery {
    private var requests: [CheckedContinuation<[StoreTransactionSnapshot], any Error>] = []
    private let started = TestSignal()

    func next() async throws -> [StoreTransactionSnapshot] {
        await started.send()
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
        }
    }

    func waitForRequest(_ count: Int) async {
        await started.wait(for: count)
    }

    func succeed(_ snapshots: [StoreTransactionSnapshot]) {
        precondition(!requests.isEmpty)
        requests.removeFirst().resume(returning: snapshots)
    }

    func fail(_ error: any Error) {
        precondition(!requests.isEmpty)
        requests.removeFirst().resume(throwing: error)
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

func makeSnapshot(
    id: UInt64,
    productID: String = "product",
    purchaseDate: Date? = nil,
    signedDate: Date? = nil,
    jws: String? = nil,
    revocationDate: Date? = nil
) -> StoreTransactionSnapshot {
    let purchaseDate = purchaseDate ?? Date(timeIntervalSince1970: TimeInterval(id))
    return StoreTransactionSnapshot(
        id: id,
        originalID: id,
        productID: productID,
        subscriptionGroupID: nil,
        productType: .consumable,
        purchaseDate: purchaseDate,
        originalPurchaseDate: purchaseDate,
        expirationDate: nil,
        revocationDate: revocationDate,
        revocationReason: nil,
        purchasedQuantity: 1,
        isUpgraded: false,
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
    let updateTermination: TestSignal
    let entitlementQueryCount: TestSignal

    init(
        currentEntitlements:
            @escaping @Sendable () async throws
            -> [StoreTransactionSnapshot] = { [] },
        history:
            @escaping @Sendable (Product.ID) async throws
            -> [StoreTransactionSnapshot] = { _ in [] },
        synchronize: @escaping @Sendable () async throws -> Void = {}
    ) {
        let updatePair = AsyncStream<StoreTransactionDelivery>.makeStream()
        let unfinishedPair = AsyncStream<StoreTransactionDelivery>.makeStream()
        let updateTermination = TestSignal()
        let entitlementQueryCount = TestSignal()
        updatePair.continuation.onTermination = { _ in
            Task { await updateTermination.send() }
        }
        self.updates = updatePair.continuation
        self.unfinished = unfinishedPair.continuation
        self.updateTermination = updateTermination
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
            currentEntitlements: {
                await entitlementQueryCount.send()
                return try await currentEntitlements()
            },
            history: history,
            synchronize: synchronize,
            purchaseDelivery: { result in
                LiveTransactionAdapter.delivery(result)
            }
        )
    }
}
