import Foundation
import StoreKit

/// A store operation that can appear in lifecycle and diagnostic errors.
public enum StoreTransactionOperation: Sendable, Hashable {
    /// Processing a direct `Product.PurchaseResult`.
    case processPurchase

    /// Refreshing the current entitlement projection.
    case refreshEntitlements

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

/// An error produced while operating a transaction store.
public enum StoreTransactionError: LocalizedError, Sendable {
    /// An irreversible StoreKit action that completed before a later operation failed.
    public enum CompletedOperation: Sendable, Hashable {
        /// The framework finished the exact transaction revision.
        case finishedTransaction(StoreTransactionSnapshot)

        /// The framework successfully synchronized purchases with the App Store.
        case synchronizedPurchases
    }

    /// The store has begun its shared close operation and accepts no new work.
    case closing

    /// The store finished closing and cannot restart.
    case closed

    /// StoreKit returned a purchase result unknown to this framework version.
    case unknownPurchaseResult

    /// Automatic handling was requested for a product outside the catalog's
    /// subscription group.
    case unhandledTransaction(
        productID: Product.ID,
        productType: Product.ProductType
    )

    /// A consumer callback attempted to reenter its own session.
    ///
    /// Reentrancy with propagated callback context is rejected because a
    /// callback can otherwise wait behind itself or attempt to close the
    /// dispatcher that is executing it. Callbacks must also avoid awaiting a
    /// detached task that calls the same store: detached tasks don't carry the
    /// callback context but can still create the same dependency cycle.
    case reentrantOperation(operation: StoreTransactionOperation)

    /// A StoreKit-backed operation was requested from a fixed override store.
    case operationUnavailableInOverride(
        operation: StoreTransactionOperation
    )

    /// Entitlement refresh failed after an irreversible StoreKit action completed.
    ///
    /// Retry ``TransactionStore/refreshEntitlements()`` instead of repeating
    /// the completed action.
    case entitlementRefreshFailed(
        after: CompletedOperation,
        underlyingError: any Error
    )

    /// A localized description of the transaction-store failure.
    public var errorDescription: String? {
        switch self {
        case .closing:
            "The transaction store is closing and cannot accept new operations."

        case .closed:
            "The transaction store is closed."

        case .unknownPurchaseResult:
            "StoreKit returned an unknown purchase result."

        case .unhandledTransaction(let productID, let productType):
            "Transaction handling is required for product \(productID) of type "
                + "\(productType.rawValue)."

        case .reentrantOperation(let operation):
            "The transaction store cannot perform \(operation.errorDescription) "
                + "from a callback owned by the same store."

        case .operationUnavailableInOverride(let operation):
            "The transaction store cannot perform \(operation.errorDescription) "
                + "when entitlements are overridden."

        case .entitlementRefreshFailed(let operation, let underlyingError):
            "Entitlement refresh failed after \(operation.errorDescription): "
                + underlyingError.localizedDescription
        }
    }

    /// A localized suggestion for recovering from the failure, when available.
    public var recoverySuggestion: String? {
        switch self {
        case .entitlementRefreshFailed:
            "Call refreshEntitlements() instead of repeating the completed StoreKit action."

        case .closing, .closed, .unknownPurchaseResult, .unhandledTransaction,
            .reentrantOperation, .operationUnavailableInOverride:
            nil
        }
    }
}

private extension StoreTransactionOperation {
    var errorDescription: String {
        switch self {
        case .processPurchase:
            "purchase processing"
        case .refreshEntitlements:
            "entitlement refresh"
        case .history:
            "a transaction history query"
        case .restorePurchases:
            "purchase restoration"
        case .close:
            "store closure"
        }
    }
}

private extension StoreTransactionError.CompletedOperation {
    var errorDescription: String {
        switch self {
        case .finishedTransaction(let transaction):
            "finishing transaction \(transaction.id) for product \(transaction.productID)"
        case .synchronizedPurchases:
            "synchronizing purchases"
        }
    }
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
