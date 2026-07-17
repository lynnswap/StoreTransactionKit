import Foundation

/// A store operation that can appear in lifecycle and diagnostic errors.
public enum StoreTransactionOperation: Sendable, Hashable {
    /// Processing a direct `Product.PurchaseResult`.
    case processPurchase

    /// Refreshing the current entitlement projection.
    case currentEntitlements

    /// Querying transaction history for one product.
    case history

    /// Synchronizing purchases and then refreshing entitlements.
    case restorePurchases

    /// Draining and closing the process-owned session.
    case close
}

package enum StoreTransactionCallback: Sendable {
    case transactionHandler
    case entitlementObserver
    case failureReporter
}

/// A failure delivered through the process-owned background reporting path.
public struct StoreTransactionBackgroundFailure: Error, Sendable {
    /// The background owner that reported the failure.
    public enum Source: Sendable, Hashable {
        /// A delivery from `Transaction.updates`.
        case updates

        /// A delivery from `Transaction.unfinished` during monitoring or reconciliation.
        case unfinished

        /// A refresh requested after background processing completed.
        case entitlementRefresh

        /// An unverified element omitted from the current entitlement projection.
        case currentEntitlementVerification

        /// A direct operation whose caller cancelled after the session accepted it.
        case abandonedDirectOperation(StoreTransactionOperation)
    }

    /// The background owner that reported the failure.
    public let source: Source

    /// The verified transaction identifier, when verification reached a transaction snapshot.
    public let transactionID: UInt64?

    /// The verified product identifier, when verification reached a transaction snapshot.
    public let productID: String?

    /// The error returned by StoreKit or an injected consumer dependency.
    public let underlyingError: any Error

    package init(
        source: Source,
        transactionID: UInt64?,
        productID: String?,
        underlyingError: any Error
    ) {
        self.source = source
        self.transactionID = transactionID
        self.productID = productID
        self.underlyingError = underlyingError
    }
}

package struct StoreTransactionFailureWithReportingOwner: Error, Sendable {
    package let underlyingError: any Error

    package init(underlyingError: any Error) {
        self.underlyingError = underlyingError
    }
}

package struct StoreTransactionFailurePropagation: Sendable {
    package let underlyingError: any Error
    package let hasReportingOwner: Bool

    package init(_ error: any Error) {
        if let owned =
            error as? StoreTransactionFailureWithReportingOwner
        {
            self.underlyingError = owned.underlyingError
            self.hasReportingOwner = true
        } else {
            self.underlyingError = error
            self.hasReportingOwner = false
        }
    }
}

/// An error caused by using a store outside its documented lifecycle.
public enum StoreTransactionError: Error, Sendable, Hashable {
    /// The store has begun its shared close operation and accepts no new work.
    case closing

    /// The store finished closing and cannot restart.
    case closed

    /// StoreKit returned a purchase result unknown to this framework version.
    case unknownPurchaseResult

    /// A consumer callback attempted to reenter its own session.
    ///
    /// Reentrancy with propagated callback context is rejected because a
    /// callback can otherwise wait behind itself or attempt to close the
    /// dispatcher that is executing it. Callbacks must also avoid awaiting a
    /// detached task that calls the same store: detached tasks don't carry the
    /// callback context but can still create the same dependency cycle.
    case reentrantOperation(operation: StoreTransactionOperation)
}

package enum StoreTransactionLifecycleError: Error, Sendable {
    case alreadyStarted
    case notStarted
}

/// An error StoreKit returns when transaction verification fails.
public struct StoreTransactionVerificationError: LocalizedError, Sendable {
    /// The verification error supplied by StoreKit.
    public let underlyingError: any Error

    /// A localized description of the underlying StoreKit verification error.
    public var errorDescription: String? {
        underlyingError.localizedDescription
    }

    package init(underlyingError: any Error) {
        self.underlyingError = underlyingError
    }
}

package enum StoreTransactionInternalError: Error, Sendable {
    case inputClosed
    case entitlementRefreshClosed
}
