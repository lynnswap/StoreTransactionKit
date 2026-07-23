import StoreKit
import Synchronization

private struct DirectOperationFailure: Error {
    let underlyingError: any Error
}

package final class StoreTransactionRuntime<Entitlement>: Sendable
where Entitlement: Hashable & Sendable {
    private struct RuntimeTasks: Sendable {
        let updates: Task<Void, Never>
        let subscriptionStatus: Task<Void, Never>
        let startup: Task<Void, Never>
    }

    private let source: StoreTransactionSource
    private let lifecycle: TransactionStoreLifecycle
    private let delegate: TransactionStoreDelegateReference
    private let core: TransactionProcessingCore<StoreTransactionSnapshot>
    private let entitlements: EntitlementRefreshCoordinator<Entitlement>
    private let failures: FailureReporterDispatcher
    private let pipeline: StoreTransactionPipeline<Entitlement>
    private let restoreCoordinator: RestoreCoordinator<Entitlement>
    private let subscriptionStatusReadiness: ProcessingReceipt<Void>
    private let producerCancellation = TaskCancellationBag()
    private let finiteTasks = TaskCompletionBag()
    private let startupCompletion: ProcessingReceipt<Void>
    private let tasks = Mutex<RuntimeTasks?>(nil)

    package init(
        sessionID: UUID,
        source: StoreTransactionSource,
        lifecycle: TransactionStoreLifecycle,
        subscriptionCatalog: AutoRenewableSubscriptionCatalog<Entitlement>,
        delegate: (any TransactionStoreDelegate)?,
        entitlementOutcome:
            @escaping @Sendable (EntitlementRefreshOutcome<Entitlement>) async
            -> Void
    ) {
        self.source = source
        self.lifecycle = lifecycle
        let startupCompletion = ProcessingReceipt<Void>()
        self.startupCompletion = startupCompletion

        let delegateReference = TransactionStoreDelegateReference(delegate)
        self.delegate = delegateReference
        let failures = FailureReporterDispatcher(
            sessionID: sessionID,
            lifetime: lifecycle,
            report: { failure in
                await delegateReference.didFail(with: failure)
            }
        )
        self.failures = failures

        let core = TransactionProcessingCore<StoreTransactionSnapshot>(
            sessionID: sessionID,
            lifetime: lifecycle,
            handle: { transaction in
                let classification: AutoRenewableSubscriptionClassification
                do {
                    classification = try subscriptionCatalog.classification(
                        of: transaction
                    )
                } catch let error as AutoRenewableSubscriptionCatalogError {
                    throw StoreTransactionCatalogFailure(error: error)
                }

                let policy = try await delegateReference.decidePolicy(
                    for: transaction
                )
                switch (classification, policy) {
                case (.managed, .automatic),
                    (.managed, .finish),
                    (.unmanaged, .finish):
                    return
                case (.unmanaged, .automatic):
                    throw StoreTransactionError.unhandledTransaction(
                        productID: transaction.productID,
                        productType: transaction.productType
                    )
                }
            }
        )
        self.core = core

        let reconciler = CurrentEntitlementReconciler(
            query: source.currentEntitlements,
            queryUnfinished: source.queryUnfinished,
            core: core
        )
        let entitlements = EntitlementRefreshCoordinator(
            query: { retryFailedTransactions in
                try await reconciler.query(
                    retryFailedTransactions: retryFailedTransactions
                )
            },
            project: {
                (entitlements: StoreEntitlements) throws(AutoRenewableSubscriptionCatalogError)
                    -> Set<Entitlement> in
                try subscriptionCatalog.activeEntitlements(in: entitlements)
            },
            didComplete: entitlementOutcome,
            failures: failures,
            lifetime: lifecycle
        )
        self.entitlements = entitlements

        let pipeline = StoreTransactionPipeline<Entitlement>(
            core: core,
            entitlements: entitlements,
            failures: failures
        )
        self.pipeline = pipeline
        self.restoreCoordinator = RestoreCoordinator(
            synchronize: source.synchronize,
            entitlements: entitlements
        )

        let subscriptionStatusReadiness = ProcessingReceipt<Void>()
        self.subscriptionStatusReadiness = subscriptionStatusReadiness
    }

    package func start() {
        let source = source
        let lifecycle = lifecycle
        let pipeline = pipeline
        let entitlements = entitlements
        let core = core
        let failures = failures
        let subscriptionStatusReadiness = subscriptionStatusReadiness
        let startupCompletion = startupCompletion

        let updatesTask = Task.detached {
            await source.runUpdates(
                { lifecycle.beginProducerIteration() },
                { delivery in
                    await pipeline.processBackground(
                        delivery,
                        source: .updates
                    )
                }
            )
        }
        let subscriptionStatusTask = Task.detached {
            await source.runSubscriptionStatusUpdates(
                { lifecycle.beginProducerIteration() },
                {
                    _ = try? await subscriptionStatusReadiness.terminalValue()
                    await pipeline.refreshEntitlements()
                }
            )
        }
        let startupTask = Task.detached {
            let reservation = await entitlements.reserve(
                retryFailedTransactions: false
            )
            let result: Result<Void, any Error>
            do {
                _ = try await reservation.receipt.terminalValue()
                result = .success(())
            } catch {
                let propagation = StoreTransactionFailurePropagation(error)
                let exposed: any Error
                if let catalogFailure =
                    propagation.underlyingError
                    as? StoreTransactionCatalogFailure
                {
                    exposed = catalogFailure.error
                } else {
                    exposed = propagation.underlyingError
                }
                if !propagation.hasReportingOwner {
                    let report = StoreTransactionBackgroundFailure(
                        source: .entitlementRefresh,
                        transactionID: nil,
                        productID: nil,
                        underlyingError: exposed
                    )
                    if let claimed = reservation.reportingAuthority
                        .failWithoutParticipant(report: report)
                    {
                        await failures.enqueue(claimed)
                    }
                }
                result = .failure(exposed)
            }
            await core.completeInitialAttempt()
            subscriptionStatusReadiness.succeed(())
            switch result {
            case .success:
                startupCompletion.succeed(())
            case .failure(let error):
                startupCompletion.fail(error)
            }
        }
        let inserted = tasks.withLock { tasks in
            guard tasks == nil else { return false }
            tasks = RuntimeTasks(
                updates: updatesTask,
                subscriptionStatus: subscriptionStatusTask,
                startup: startupTask
            )
            return true
        }
        precondition(inserted, "A transaction runtime can start only once.")
        producerCancellation.insert(updatesTask)
        producerCancellation.insert(subscriptionStatusTask)
        finiteTasks.insert(startupTask)
    }

    package func process(
        _ result: Product.PurchaseResult,
        leases: FiniteOperationLeases
    ) async throws -> StorePurchaseOutcome {
        switch result {
        case .success(let verificationResult):
            return try await processAccepted(
                source.purchaseDelivery(verificationResult),
                leases: leases
            )
        case .pending:
            return try finishImmediate(
                leases: leases,
                outcome: .pending
            )
        case .userCancelled:
            return try finishImmediate(
                leases: leases,
                outcome: .userCancelled
            )
        @unknown default:
            leases.work.end()
            leases.observer.end()
            throw StoreTransactionError.unknownPurchaseResult
        }
    }

    package func process(
        _ delivery: StoreTransactionDelivery,
        leases: FiniteOperationLeases,
        didAdmit: @escaping @Sendable () async -> Void = {}
    ) async throws -> StorePurchaseOutcome {
        return try await processAccepted(
            delivery,
            leases: leases,
            didAdmit: didAdmit
        )
    }

    private func processAccepted(
        _ delivery: StoreTransactionDelivery,
        leases: FiniteOperationLeases,
        didAdmit: @escaping @Sendable () async -> Void = {}
    ) async throws -> StorePurchaseOutcome {
        if case .unverified(_, let error) = delivery {
            return try await failAdmittedDelivery(
                error,
                leases: leases,
                didAdmit: didAdmit
            )
        }

        let accepted:
            (
                snapshot: StoreTransactionSnapshot,
                acceptance: ProcessingAcceptance<StoreTransactionSnapshot>,
                retryFailedTransactions: Bool
            )
        let observation = DirectOperationObservation()
        do {
            accepted = try await pipeline.accept(
                delivery,
                directObservation: observation
            )
        } catch {
            leases.work.end()
            leases.observer.end()
            throw exposedError(error)
        }

        guard let binding = accepted.acceptance.directBinding else {
            preconditionFailure("A direct transaction lost its reporting binding.")
        }
        let claim = await accepted.acceptance.claimCausalResolutionIfOwner()
        await didAdmit()
        let operationReceipt = ProcessingReceipt<StoreTransactionSnapshot>()
        let task = Task {
            defer { leases.work.end() }
            do {
                _ = try await accepted.acceptance.receipt.terminalValue()
            } catch {
                if let claim {
                    await entitlements.resolve(claim, failure: error)
                }
                _ = try? await accepted.acceptance.causalReceipt.terminalValue()
                operationReceipt.fail(
                    await directFailure(
                        observation: observation,
                        binding: binding,
                        propagating: error,
                        reportsWhenAbandoned: true,
                        operation: .processPurchase,
                        snapshot: accepted.snapshot
                    )
                )
                return
            }

            if let claim {
                let refresh = await entitlements.reserve(
                    retryFailedTransactions: accepted.retryFailedTransactions,
                    reportingAuthority:
                        accepted.acceptance.reportingAuthority
                )
                do {
                    _ = try await refresh.receipt.terminalValue()
                    await claim.succeed()
                } catch {
                    await claim.fail(error)
                }
            }

            do {
                _ = try await accepted.acceptance.causalReceipt.terminalValue()
                observation.succeed(binding)
                operationReceipt.succeed(accepted.snapshot)
            } catch {
                operationReceipt.fail(
                    await directFailure(
                        observation: observation,
                        binding: binding,
                        propagating: completedTransactionFailure(
                            snapshot: accepted.snapshot,
                            error: error
                        ),
                        reportsWhenAbandoned: true,
                        operation: .processPurchase,
                        snapshot: accepted.snapshot,
                        backgroundError: exposedError(error)
                    )
                )
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            observation: observation,
            observerLease: leases.observer
        ) { .completed($0) }
    }

    private func failAdmittedDelivery(
        _ error: any Error,
        leases: FiniteOperationLeases,
        didAdmit: @escaping @Sendable () async -> Void
    ) async throws -> StorePurchaseOutcome {
        let observation = DirectOperationObservation()
        let binding = observation.bind(
            to: DirectOperationReportingAuthority()
        )
        await didAdmit()
        let operationReceipt = ProcessingReceipt<StoreTransactionSnapshot>()
        let task = Task {
            defer { leases.work.end() }
            operationReceipt.fail(
                await directFailure(
                    observation: observation,
                    binding: binding,
                    propagating: error,
                    reportsWhenAbandoned: true,
                    operation: .processPurchase,
                    snapshot: nil
                )
            )
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            observation: observation,
            observerLease: leases.observer
        ) { .completed($0) }
    }

    package func currentEntitlements(
        leases: FiniteOperationLeases
    ) async throws -> StoreEntitlements {
        let retryFailedTransactions =
            await core.retryFailedTransactionsInNewAttempt()
        let observation = DirectOperationObservation()
        let refresh = await entitlements.reserve(
            retryFailedTransactions: retryFailedTransactions,
            directObservation: observation
        )
        guard let binding = refresh.directBinding else {
            preconditionFailure("A direct refresh lost its reporting binding.")
        }
        let operationReceipt = ProcessingReceipt<EntitlementPublication<Entitlement>>()
        let task = Task {
            defer { leases.work.end() }
            do {
                let publication = try await refresh.receipt.terminalValue()
                observation.succeed(binding)
                operationReceipt.succeed(publication)
            } catch {
                operationReceipt.fail(
                    await directFailure(
                        observation: observation,
                        binding: binding,
                        propagating: error,
                        reportsWhenAbandoned: refresh.role == .owner,
                        operation: .refreshEntitlements,
                        snapshot: nil
                    )
                )
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            observation: observation,
            observerLease: leases.observer
        ) { $0.entitlements }
    }

    package func history(
        for productID: Product.ID,
        leases: FiniteOperationLeases
    ) async throws -> [StoreTransactionSnapshot] {
        let observation = DirectOperationObservation()
        let binding = observation.bind(
            to: DirectOperationReportingAuthority()
        )
        let operationReceipt = ProcessingReceipt<[StoreTransactionSnapshot]>()
        let task = Task {
            defer { leases.work.end() }
            do {
                let snapshots = try await source.history(productID)
                    .sorted(by: Self.historyOrder)
                observation.succeed(binding)
                operationReceipt.succeed(snapshots)
            } catch {
                operationReceipt.fail(
                    await directFailure(
                        observation: observation,
                        binding: binding,
                        propagating: error,
                        reportsWhenAbandoned: true,
                        operation: .history,
                        snapshot: nil
                    )
                )
            }
        }
        finiteTasks.insert(task)
        return try await outcome(
            receipt: operationReceipt,
            observation: observation,
            observerLease: leases.observer
        ) { $0 }
    }

    package func restorePurchases(
        leases: FiniteOperationLeases
    ) async throws -> StoreEntitlements {
        let retryFailedTransactions =
            await core.retryFailedTransactionsInNewAttempt()
        let observation = DirectOperationObservation()
        let restore = await restoreCoordinator.reserve(
            retryFailedTransactions: retryFailedTransactions,
            directObservation: observation
        )
        guard let binding = restore.directBinding else {
            preconditionFailure("A direct restore lost its reporting binding.")
        }
        let operationReceipt = ProcessingReceipt<EntitlementPublication<Entitlement>>()
        let task = Task {
            defer { leases.work.end() }
            do {
                let publication = try await restore.receipt.terminalValue()
                observation.succeed(binding)
                operationReceipt.succeed(publication)
            } catch let failure as RestoreCoordinatorFailure {
                let exposed = exposedError(failure.underlyingError)
                let directError: any Error
                if failure.synchronized {
                    directError = StoreTransactionError.entitlementRefreshFailed(
                        after: .synchronizedPurchases,
                        underlyingError: exposed
                    )
                } else {
                    directError = exposed
                }
                operationReceipt.fail(
                    await directFailure(
                        observation: observation,
                        binding: binding,
                        propagating: directError,
                        reportsWhenAbandoned:
                            restore.role == .owner
                            && failure.reportsWhenAbandoned,
                        operation: .restorePurchases,
                        snapshot: nil,
                        backgroundError: exposed
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
            observation: observation,
            observerLease: leases.observer
        ) { $0.entitlements }
    }

    package func waitForInitialReadiness() async throws {
        do {
            try await startupCompletion.value()
        } catch is ProcessingReceiptWaiterCancellation {
            throw CancellationError()
        }
    }

    package func shutdown() async {
        let tasks = tasks.withLock { tasks -> RuntimeTasks in
            guard let tasks else {
                preconditionFailure("A transaction runtime was closed before start.")
            }
            return tasks
        }
        producerCancellation.cancel()
        tasks.startup.cancel()
        await tasks.updates.value
        await tasks.subscriptionStatus.value
        await lifecycle.waitForProducerIterations()
        await lifecycle.waitForOperations()
        await finiteTasks.waitForAll()
        await entitlements.sealAndDrain()
        await core.finishInputAndDrain()
        await failures.sealAndDrain()
        delegate.release()
        producerCancellation.removeAll()
    }

    package func cancelSynchronously() {
        lifecycle.sealSynchronously()
        producerCancellation.cancel()
        finiteTasks.cancel()
        restoreCoordinator.cancelSynchronously()
        core.cancelSynchronously()
        entitlements.cancelSynchronously()
        failures.cancelSynchronously()
    }

    private func finishImmediate(
        leases: FiniteOperationLeases,
        outcome: StorePurchaseOutcome
    ) throws -> StorePurchaseOutcome {
        do {
            try Task.checkCancellation()
        } catch {
            leases.work.end()
            leases.observer.end()
            throw error
        }
        leases.work.end()
        leases.observer.end()
        return outcome
    }

    private func outcome<Value: Sendable, Output>(
        receipt: ProcessingReceipt<Value>,
        observation: DirectOperationObservation,
        observerLease: FiniteOperationLease,
        transform: (Value) -> Output
    ) async throws -> Output {
        do {
            let value = try await receipt.value()
            observation.deliver()
            observerLease.end()
            return transform(value)
        } catch is ProcessingReceiptWaiterCancellation {
            if let report = observation.abandon() {
                await failures.enqueue(report)
            }
            observerLease.end()
            throw CancellationError()
        } catch let failure as DirectOperationFailure {
            observation.deliver()
            observerLease.end()
            throw failure.underlyingError
        } catch {
            observation.deliver()
            observerLease.end()
            throw error
        }
    }

    private func directFailure(
        observation: DirectOperationObservation,
        binding: DirectOperationObservation.Binding,
        propagating error: any Error,
        reportsWhenAbandoned: Bool,
        operation: StoreTransactionOperation,
        snapshot: StoreTransactionSnapshot?,
        backgroundError: (any Error)? = nil
    ) async -> DirectOperationFailure {
        let propagation = StoreTransactionFailurePropagation(error)
        let exposed = exposedError(propagation.underlyingError)
        let report: StoreTransactionBackgroundFailure?
        if reportsWhenAbandoned && !propagation.hasReportingOwner {
            report = StoreTransactionBackgroundFailure(
                source: .abandonedDirectOperation(operation),
                transactionID: snapshot?.id,
                productID: snapshot?.productID,
                underlyingError: backgroundError.map(exposedError) ?? exposed
            )
        } else {
            report = nil
        }
        if let claimed = observation.fail(binding, report: report) {
            await failures.enqueue(claimed)
        }
        return DirectOperationFailure(
            underlyingError: exposed
        )
    }

    private func completedTransactionFailure(
        snapshot: StoreTransactionSnapshot,
        error: any Error
    ) -> any Error {
        let propagation = StoreTransactionFailurePropagation(error)
        let publicError = StoreTransactionError.entitlementRefreshFailed(
            after: .finishedTransaction(snapshot),
            underlyingError: exposedError(propagation.underlyingError)
        )
        if propagation.hasReportingOwner {
            return StoreTransactionFailureWithReportingOwner(
                underlyingError: publicError
            )
        }
        return publicError
    }

    private func exposedError(_ error: any Error) -> any Error {
        let propagation = StoreTransactionFailurePropagation(error)
        if let catalogFailure =
            propagation.underlyingError as? StoreTransactionCatalogFailure
        {
            return catalogFailure.error
        }
        return propagation.underlyingError
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
