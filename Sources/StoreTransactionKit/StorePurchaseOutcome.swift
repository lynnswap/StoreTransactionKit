/// The semantic result of processing a direct StoreKit purchase result.
public enum StorePurchaseOutcome: Sendable, Hashable {
    /// StoreTransactionKit verified, finished, reconciled, and published the
    /// transaction.
    case completed(StoreTransactionSnapshot)

    /// StoreTransactionKit verified and published an unrecognized subscription
    /// without finishing it.
    case leftUnfinished(StoreTransactionSnapshot)

    /// The purchase is awaiting an external action and may arrive through transaction updates later.
    case pending

    /// The customer cancelled the purchase confirmation.
    case userCancelled
}
