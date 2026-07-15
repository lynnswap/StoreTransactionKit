/// The semantic result of processing a direct StoreKit purchase result.
public enum StorePurchaseOutcome: Sendable {
    /// StoreTransactionKit verified, durably handled, finished, and refreshed the transaction.
    case completed(StoreTransactionSnapshot)

    /// The purchase is awaiting an external action and may arrive through transaction updates later.
    case pending

    /// The customer cancelled the purchase confirmation.
    case userCancelled
}
