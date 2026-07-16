import StoreKit

private struct DirectOperationFailure: Error {
    let underlyingError: any Error
    let reportsWhenAbandoned: Bool
}

package final class StoreTransactionRuntime: Sendable {
    private let source: StoreTransactionSource
    private let core: TransactionProcessingCore<StoreTransactionSnapshot>
    private let entitlements: EntitlementRefreshCoordinator
    private let failures: FailureReporterDispatcher
    private let pipeline: StoreTransactionPipeline
    private let restoreCoordinator: RestoreCoordinator
    private let operations = FiniteOperationRegistry()
    private let readinessLease: FiniteOperationLease
    private let subscriptionStatusReadiness: ProcessingReceipt<Void>
    private let producerCancellation = TaskCancellationBag()
    private let finiteTasks = TaskCompletionBag()
    private let updatesTask: Task<Void, Never>
    private let unfinishedTask: Task<Void, Never>
    private let subscriptionStatusTask: Task<Void, Never>

    package init(
        sessionID: UUID,
        source: StoreTransactionSource,
        handleTransaction:
            @escaping @Sendable (StoreTransactionSnapshot) async throws -> Void,
        entitlementsDidChange:
            @escaping @Sendable (StoreEntitlements) async -> Void,
        reportFailure:
            @escaping @Sendable (StoreTransactionBackgroundFailure) async -> Void
    ) {
        self.source = source

        let core = TransactionProcessingCore(
            sessionID: sessionID,
            handle: handleTransaction
        )
        let failures = FailureReporterDispatcher(
            sessionID: sessionID,
            report: reportFailure
        )
        let currentEntitlements = CurrentEntitlementReconciler(
            query: source.currentEntitlements,
            queryUnfinished: source.queryUnfinished,
            core: core,
            failures: failures
        )
        let entitlements = EntitlementRefreshCoordinator(
            sessionID: sessionID,
            query: currentEntitlements.query,
            didChange: entitlementsDidChange
        )
        let pipeline = StoreTransactionPipeline(
            core: core,
            entitlements: entitlements,
            failures: failures
        )
        self.core = core
        self.entitlements = entitlements
        self.failures = failures
        self.pipeline = pipeline
        self.restoreCoordinator = RestoreCoordinator(
            synchronize: source.synchronize,
            entitlements: entitlements
        )
        self.readinessLease = operations.begin()!
        let subscriptionStatusReadiness = ProcessingReceipt<Void>()
        self.subscriptionStatusReadiness = subscriptionStatusReadiness

        self.updatesTask = Task.detached {
            await source.runUpdates { delivery in
                await pipeline.processBackground(delivery, source: .updates)
            }
        }
        self.unfinishedTask = Task.detached {
            await source.runUnfinished { delivery in
                await pipeline.processBackground(delivery, source: .unfinished)
            }
        }
        self.subscriptionStatusTask = Task.detached {
            await source.runSubscriptionStatusUpdates {
                do {
                    _ = try await subscriptionStatusReadiness.value()
                } catch is ProcessingReceiptWaiterCancellation {
                    return
                } catch {
                    preconditionFailure(
                        "Subscription status readiness cannot fail: \(error)"
                    )
                }
                await pipeline.refreshEntitlements()
            }
        }
        producerCancellation.insert(updatesTask)
        producerCancellation.insert(unfinishedTask)
        producerCancellation.insert(subscriptionStatusTask)
    }

    package func beginOperation() -> FiniteOperationLeases? {
        operations.beginPair()
    }

    package func readiness() async throws -> StoreTransactionReadiness {
        defer {
            subscriptionStatusReadiness.succeed(())
            readinessLease.end()
        }
        await unfinishedTask.value
        let reservation = await entitlements.reserve()
        do {
            return StoreTransactionReadiness(
                entitlements: try await reservation.receipt.value()
            )
        } catch is ProcessingReceiptWaiterCancellation {
            throw CancellationError()
        }
    }

    package func process(
        _ result: Product.PurchaseResult,
        leases: FiniteOperationLeases
    ) async throws -> StorePurchaseOutcome {
        switch result {
        case .success(let verificationResult):
            return try await process(
                source.purchaseDelivery(verificationResult),
                leases: leases
            )
        case .pending:
            do {
                try Task.checkCancellation()
            } catch {
                leases.work.end()
                leases.observer.end()
                throw error
            }
            leases.work.end()
            leases.observer.end()
            return .pending
        case .userCancelled:
            do {
                try Task.checkCancellation()
            } catch {
                leases.work.end()
                leases.observer.end()
                throw error
            }
            leases.work.end()
            leases.observer.end()
            return .userCancelled
        @unknown default:
            leases.work.end()
            leases.observer.end()
            throw StoreTransactionError.unknownPurchaseResult
        }
    }

    package func process(
        _ delivery: StoreTransactionDelivery,
        leases: FiniteOperationLeases
    ) async throws -> StorePurchaseOutcome {
        let accepted:
            (
                snapshot: StoreTransactionSnapshot,
                acceptance: ProcessingAcceptance<StoreTransactionSnapshot>
            )
        do {
            accepted = try await pipeline.accept(delivery)
        } catch {
            leases.work.end()
            leases.observer.end()
            throw error
        }
        let operationReceipt = ProcessingReceipt<StoreTransactionSnapshot>()
        let entitlements = entitlements
        let task = Task {
            defer { leases.work.end() }
            let snapshot: StoreTransactionSnapshot
            do {
                snapshot = try await accepted.acceptance.receipt
                    .terminalValue()
            } catch {
                operationReceipt.fail(
                    DirectOperationFailure(
                        underlyingError: error,
                        reportsWhenAbandoned:
                            accepted.acceptance.role == .owner
                    )
                )
                return
            }

            let refresh = await entitlements.reserve()
            do {
                _ = try await refresh.receipt.terminalValue()
                operationReceipt.succeed(snapshot)
            } catch {
                operationReceipt.fail(
                    DirectOperationFailure(
                        underlyingError: error,
                        reportsWhenAbandoned: refresh.role == .owner
                    )
                )
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            operation: .processPurchase,
            snapshot: accepted.snapshot,
            observerLease: leases.observer
        ) { .completed($0) }
    }

    package func currentEntitlements(
        leases: FiniteOperationLeases
    ) async throws -> StoreEntitlements {
        let operationReceipt = ProcessingReceipt<StoreEntitlements>()
        let entitlements = entitlements
        let task = Task {
            defer { leases.work.end() }
            let refresh = await entitlements.reserve()
            do {
                operationReceipt.succeed(
                    try await refresh.receipt.terminalValue()
                )
            } catch {
                operationReceipt.fail(
                    DirectOperationFailure(
                        underlyingError: error,
                        reportsWhenAbandoned: refresh.role == .owner
                    )
                )
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            operation: .currentEntitlements,
            snapshot: nil,
            observerLease: leases.observer
        ) { $0 }
    }

    package func history(
        for productID: Product.ID,
        leases: FiniteOperationLeases
    ) async throws -> [StoreTransactionSnapshot] {
        let operationReceipt = ProcessingReceipt<[StoreTransactionSnapshot]>()
        let source = source
        let task = Task {
            defer { leases.work.end() }
            do {
                let snapshots = try await source.history(productID)
                    .sorted(by: Self.historyOrder)
                operationReceipt.succeed(snapshots)
            } catch {
                operationReceipt.fail(error)
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            operation: .history,
            snapshot: nil,
            observerLease: leases.observer
        ) { $0 }
    }

    package func restorePurchases(
        leases: FiniteOperationLeases
    ) async throws -> StoreEntitlements {
        let restore = await restoreCoordinator.reserve()
        let operationReceipt = ProcessingReceipt<StoreEntitlements>()
        let task = Task {
            defer { leases.work.end() }
            do {
                operationReceipt.succeed(
                    try await restore.receipt.terminalValue()
                )
            } catch let failure as RestoreCoordinatorFailure {
                operationReceipt.fail(
                    DirectOperationFailure(
                        underlyingError: failure.underlyingError,
                        reportsWhenAbandoned:
                            restore.role == .owner
                            && failure.reportsWhenAbandoned
                    )
                )
            } catch {
                preconditionFailure(
                    "RestoreCoordinator exposed an unclassified failure: \(error)"
                )
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            operation: .restorePurchases,
            snapshot: nil,
            observerLease: leases.observer
        ) { $0 }
    }

    package func close() async {
        producerCancellation.cancel()
        await updatesTask.value
        await unfinishedTask.value
        await subscriptionStatusTask.value
        await operations.stopAdmissionAndWait()
        await finiteTasks.waitForAll()
        await entitlements.sealAndDrain()
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
        producerCancellation.removeAll()
    }

    package func cancelSynchronously() {
        producerCancellation.cancel()
        finiteTasks.cancel()
    }

    private func outcome<Value: Sendable, Output>(
        receipt: ProcessingReceipt<Value>,
        operation: StoreTransactionOperation,
        snapshot: StoreTransactionSnapshot?,
        observerLease: FiniteOperationLease,
        transform: (Value) -> Output
    ) async throws -> Output {
        do {
            let value = try await receipt.value()
            observerLease.end()
            return transform(value)
        } catch is ProcessingReceiptWaiterCancellation {
            let failures = failures
            let task = Task {
                defer { observerLease.end() }
                do {
                    _ = try await receipt.terminalValue()
                } catch let failure as DirectOperationFailure {
                    guard failure.reportsWhenAbandoned else { return }
                    await failures.enqueue(
                        StoreTransactionBackgroundFailure(
                            source: .abandonedDirectOperation(operation),
                            transactionID: snapshot?.id,
                            productID: snapshot?.productID,
                            underlyingError: failure.underlyingError
                        )
                    )
                } catch {
                    await failures.enqueue(
                        StoreTransactionBackgroundFailure(
                            source: .abandonedDirectOperation(operation),
                            transactionID: snapshot?.id,
                            productID: snapshot?.productID,
                            underlyingError: error
                        ))
                }
            }
            finiteTasks.insert(task)
            throw CancellationError()
        } catch let failure as DirectOperationFailure {
            observerLease.end()
            throw failure.underlyingError
        } catch {
            observerLease.end()
            throw error
        }
    }

    package static func historyOrder(
        _ lhs: StoreTransactionSnapshot,
        _ rhs: StoreTransactionSnapshot
    ) -> Bool {
        if lhs.purchaseDate != rhs.purchaseDate {
            return lhs.purchaseDate > rhs.purchaseDate
        }
        if lhs.signedDate != rhs.signedDate {
            return lhs.signedDate > rhs.signedDate
        }
        if lhs.id != rhs.id {
            return lhs.id > rhs.id
        }
        return Data(lhs.jwsRepresentation.utf8)
            .lexicographicallyPrecedes(Data(rhs.jwsRepresentation.utf8))
    }
}
