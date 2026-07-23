import StoreTransactionKit
import StoreKit

public enum SubscriptionEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

public enum Plans: AutoRenewableSubscriptionGroup<SubscriptionEntitlement> {
    public static let id = SubscriptionGroupID(
        rawValue: "external-consumer.subscription-group"
    )

    public enum ProductID: String, Hashable, Sendable {
        case tier1_Monthly = "external-consumer.subscription.tier1.monthly"
        case tier1_Yearly = "external-consumer.subscription.tier1.yearly"
        case tier2_Monthly = "external-consumer.subscription.tier2.monthly"
        case tier2_Yearly = "external-consumer.subscription.tier2.yearly"
    }

    public static var subscriptions: StoreSubscriptions {
        StoreSubscription(.tier1_Monthly, entitlement: .tier1)
        StoreSubscription(.tier1_Yearly, entitlement: .tier1)
        StoreSubscription(.tier2_Monthly, entitlement: .tier2)
        StoreSubscription(.tier2_Yearly, entitlement: .tier2)
    }
}

public let subscriptionCatalog = AutoRenewableSubscriptionCatalog(Plans.self)

public let subscriptionProductIDs = subscriptionCatalog.productIDs

public func loadDeclaredSubscriptionProducts() async throws -> [Product] {
    try await Product.products(for: subscriptionCatalog.productIDs)
}

public func loadSubscriptionStatuses() async throws
    -> [Product.SubscriptionInfo.Status]
{
    try await Product.SubscriptionInfo.status(
        for: subscriptionCatalog.subscriptionGroupID.rawValue
    )
}

public func entitlement(
    for productID: String
) -> SubscriptionEntitlement? {
    subscriptionCatalog.entitlement(for: productID)
}

public let legacySubscriptionProductID =
    "external-consumer.subscription.legacy"

@MainActor
public final class NotesViewModel {
    private let store: TransactionStore<SubscriptionEntitlement>

    public var hasPremiumAccess: Bool {
        store.isEntitled(to: .tier1)
            || store.isEntitled(to: .tier2)
    }

    public var canExportPDF: Bool {
        store.isEntitled(to: .tier1)
    }

    public init(store: TransactionStore<SubscriptionEntitlement>) {
        self.store = store
    }
}

public actor AppTransactionDelegate: TransactionStoreDelegate {
    public init() {}

    public func decidePolicy(
        for transaction: StoreTransactionSnapshot
    ) async throws -> StoreTransactionHandlingPolicy {
        .automatic
    }

    public func didFail(
        with failure: StoreTransactionBackgroundFailure
    ) async {
        print("Background failure from \(failure.source)")
    }
}

public actor AppUnrecognizedSubscriptionDelegate:
    UnrecognizedSubscriptionDelegate<SubscriptionEntitlement>
{
    public init() {}

    public func decidePolicy(
        forUnrecognizedSubscription transaction: StoreTransactionSnapshot
    ) async throws -> UnrecognizedSubscriptionPolicy<SubscriptionEntitlement> {
        if transaction.productID == legacySubscriptionProductID {
            .treatAs(.tier1)
        } else {
            .leaveUnfinished
        }
    }
}

@main
@MainActor
struct Consumer {
    static func main() async throws {
        let delegate = AppTransactionDelegate()
        let unrecognizedSubscriptionDelegate =
            AppUnrecognizedSubscriptionDelegate()
        let store = TransactionStore(
            subscriptionCatalog: subscriptionCatalog,
            delegate: delegate,
            unrecognizedSubscriptionDelegate:
                unrecognizedSubscriptionDelegate
        )
        let viewModel = NotesViewModel(store: store)
        print("Has premium access: \(viewModel.hasPremiumAccess)")
        try await store.close()
    }
}
