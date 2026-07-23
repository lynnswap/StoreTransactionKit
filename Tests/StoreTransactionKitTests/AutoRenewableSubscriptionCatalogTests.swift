import Foundation
import StoreKit
import Synchronization
import Testing
@testable import StoreTransactionKit

@Suite("Auto-renewable subscription catalog")
struct AutoRenewableSubscriptionCatalogTests {
    @Test("the declaration is evaluated once and normalized into one lookup")
    func evaluatesDeclarationOnce() throws {
        countingSubscriptionsAccessCount.withLock { count in
            count = 0
        }

        let catalog = AutoRenewableSubscriptionCatalog(CountingPlans.self)

        #expect(countingSubscriptionsAccessCount.withLock { $0 } == 1)
        #expect(catalog.subscriptionGroupID == CountingPlans.id)
        #expect(catalog.isDeclared(by: CountingPlans.self))
        #expect(!catalog.isDeclared(by: OtherPlans.self))
        #expect(catalog.contains(productID: CountingPlans.ProductID.monthly.rawValue))
        #expect(!catalog.contains(productID: "com.example.subscription.undeclared"))

        let transaction = subscriptionSnapshot(
            id: 0,
            productID: CountingPlans.ProductID.monthly.rawValue,
            subscriptionGroupID: CountingPlans.id.rawValue
        )
        #expect(try catalog.classification(of: transaction) == .managed)
        #expect(
            try catalog.activeEntitlements(
                in: StoreEntitlements(transactions: [transaction])
            ) == [.tier1]
        )
        #expect(countingSubscriptionsAccessCount.withLock { $0 } == 1)
    }

    @Test("monthly and yearly products project to their declared entitlements")
    func projectsDeclaredEntitlements() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let entitlements = StoreEntitlements(
            transactions: [
                subscriptionSnapshot(
                    id: 1,
                    productID: Plans.ProductID.tier1_Monthly.rawValue
                ),
                subscriptionSnapshot(
                    id: 2,
                    productID: Plans.ProductID.tier1_Yearly.rawValue
                ),
                subscriptionSnapshot(
                    id: 3,
                    productID: Plans.ProductID.tier2_Monthly.rawValue
                ),
                subscriptionSnapshot(
                    id: 4,
                    productID: Plans.ProductID.tier2_Yearly.rawValue
                ),
            ]
        )

        #expect(
            try catalog.activeEntitlements(in: entitlements)
                == [.tier1, .tier2]
        )
    }

    @Test("an upgraded declared product remains managed without granting access")
    func upgradedDeclaredProductDoesNotGrantAccess() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let transaction = subscriptionSnapshot(
            id: 5,
            productID: Plans.ProductID.tier1_Monthly.rawValue,
            isUpgraded: true
        )

        #expect(try catalog.classification(of: transaction) == .managed)
        #expect(
            try catalog.activeEntitlements(
                in: StoreEntitlements(transactions: [transaction])
            ).isEmpty
        )
    }

    @Test("a retired upgraded product remains managed without granting access")
    func retiredUpgradedProductDoesNotGrantAccess() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let transaction = subscriptionSnapshot(
            id: 6,
            productID: "com.example.subscription.retired",
            isUpgraded: true
        )

        #expect(try catalog.classification(of: transaction) == .managed)
        #expect(
            try catalog.activeEntitlements(
                in: StoreEntitlements(transactions: [transaction])
            ).isEmpty
        )
    }

    @Test("a product outside the catalog group remains unmanaged and unprojected")
    func externalProductIsUnmanaged() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let transaction = subscriptionSnapshot(
            id: 7,
            productID: "com.example.other.product",
            subscriptionGroupID: "other-group"
        )

        #expect(try catalog.classification(of: transaction) == .unmanaged)
        #expect(
            try catalog.activeEntitlements(
                in: StoreEntitlements(transactions: [transaction])
            ).isEmpty
        )
    }

    @Test("a declared product with a wrong StoreKit type fails validation")
    func declaredProductTypeMismatch() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = Plans.ProductID.tier1_Monthly.rawValue

        do {
            _ = try catalog.activeEntitlements(
                in: StoreEntitlements(
                    transactions: [
                        subscriptionSnapshot(
                            id: 8,
                            productID: productID,
                            productType: .nonConsumable
                        )
                    ]
                )
            )
            Issue.record("Projection unexpectedly accepted a non-consumable product.")
        } catch let error as AutoRenewableSubscriptionCatalogError {
            guard case let .productTypeMismatch(actualProductID, actual) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }

            #expect(actualProductID == productID)
            #expect(actual == .nonConsumable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("a declared product with a wrong group fails validation")
    func declaredProductGroupMismatch() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = Plans.ProductID.tier1_Monthly.rawValue

        do {
            _ = try catalog.classification(
                of: subscriptionSnapshot(
                    id: 9,
                    productID: productID,
                    subscriptionGroupID: "other-group"
                )
            )
            Issue.record("Classification unexpectedly accepted the wrong group.")
        } catch let error as AutoRenewableSubscriptionCatalogError {
            guard
                case let .subscriptionGroupMismatch(
                    actualProductID,
                    expected,
                    actual
                ) = error
            else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }

            #expect(actualProductID == productID)
            #expect(expected == Plans.id)
            #expect(actual == "other-group")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("an undeclared current product in the managed group fails validation")
    func undeclaredCurrentProduct() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = "com.example.subscription.undeclared"

        do {
            _ = try catalog.activeEntitlements(
                in: StoreEntitlements(
                    transactions: [
                        subscriptionSnapshot(
                            id: 10,
                            productID: productID
                        )
                    ]
                )
            )
            Issue.record("Projection unexpectedly accepted an undeclared product.")
        } catch let error as AutoRenewableSubscriptionCatalogError {
            guard
                case let .undeclaredProduct(
                    actualProductID,
                    subscriptionGroupID
                ) = error
            else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }

            #expect(actualProductID == productID)
            #expect(subscriptionGroupID == Plans.id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("an undeclared upgraded product still requires an auto-renewable type")
    func retiredProductTypeMismatch() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = "com.example.subscription.retired"

        do {
            _ = try catalog.classification(
                of: subscriptionSnapshot(
                    id: 11,
                    productID: productID,
                    productType: .nonRenewable,
                    isUpgraded: true
                )
            )
            Issue.record("Classification unexpectedly accepted the wrong type.")
        } catch let error as AutoRenewableSubscriptionCatalogError {
            guard case let .productTypeMismatch(actualProductID, actual) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }

            #expect(actualProductID == productID)
            #expect(actual == .nonRenewable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("projection validates the complete candidate before returning a set")
    func projectionIsAllOrNothing() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)

        do {
            _ = try catalog.activeEntitlements(
                in: StoreEntitlements(
                    transactions: [
                        subscriptionSnapshot(
                            id: 12,
                            productID: Plans.ProductID.tier1_Monthly.rawValue
                        ),
                        subscriptionSnapshot(
                            id: 13,
                            productID: "com.example.subscription.undeclared"
                        ),
                    ]
                )
            )
            Issue.record("Projection unexpectedly returned a partial set.")
        } catch let error as AutoRenewableSubscriptionCatalogError {
            guard case .undeclaredProduct = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("an empty group identifier is a construction error")
    func emptyGroupIDFails() async {
        await #expect(processExitsWith: .failure) {
            _ = SubscriptionGroupID(rawValue: "")
        }
    }

    @Test("an empty subscription declaration is a construction error")
    func emptyDeclarationFails() async {
        await #expect(processExitsWith: .failure) {
            _ = AutoRenewableSubscriptionCatalog(EmptyPlans.self)
        }
    }

    @Test("an empty product identifier is a construction error")
    func emptyProductIDFails() async {
        await #expect(processExitsWith: .failure) {
            _ = AutoRenewableSubscriptionCatalog(EmptyProductIDPlans.self)
        }
    }

    @Test("duplicate raw product identifiers are a construction error")
    func duplicateProductIDFails() async {
        await #expect(processExitsWith: .failure) {
            _ = AutoRenewableSubscriptionCatalog(DuplicateProductIDPlans.self)
        }
    }
}

private enum SubscriptionEntitlement: Hashable, Sendable {
    case tier1
    case tier2
}

private enum Plans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement>
{
    static let id = SubscriptionGroupID(rawValue: "example-group")

    enum ProductID: String, Hashable, Sendable {
        case tier1_Monthly = "com.example.subscription.tier1.monthly"
        case tier1_Yearly = "com.example.subscription.tier1.yearly"
        case tier2_Monthly = "com.example.subscription.tier2.monthly"
        case tier2_Yearly = "com.example.subscription.tier2.yearly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.tier1_Monthly, entitlement: .tier1)
        StoreSubscription(.tier1_Yearly, entitlement: .tier1)
        StoreSubscription(.tier2_Monthly, entitlement: .tier2)
        StoreSubscription(.tier2_Yearly, entitlement: .tier2)
    }
}

private enum OtherPlans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement>
{
    static let id = Plans.id

    enum ProductID: String, Hashable, Sendable {
        case monthly = "com.example.subscription.tier1.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.monthly, entitlement: .tier2)
    }
}

private let countingSubscriptionsAccessCount = Mutex(0)

private enum CountingPlans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement>
{
    static let id = SubscriptionGroupID(rawValue: "counting-group")

    enum ProductID: String, Hashable, Sendable {
        case monthly = "com.example.counting.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        countingSubscriptionsAccessCount.withLock { count in
            count += 1
        }

        return [StoreSubscription(.monthly, entitlement: .tier1)]
    }
}

private enum EmptyPlans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement>
{
    static let id = SubscriptionGroupID(rawValue: "empty-group")

    enum ProductID: String, Hashable, Sendable {
        case monthly = "com.example.empty.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        return []
    }
}

private enum EmptyProductIDPlans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement>
{
    static let id = SubscriptionGroupID(rawValue: "empty-product-group")

    enum ProductID: String, Hashable, Sendable {
        case empty = ""
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.empty, entitlement: .tier1)
    }
}

private struct DuplicateProductID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    static let first = Self(rawValue: "com.example.duplicate")
    static let second = Self(rawValue: "com.example.duplicate")
}

private enum DuplicateProductIDPlans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement>
{
    static let id = SubscriptionGroupID(rawValue: "duplicate-product-group")

    typealias ProductID = DuplicateProductID

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.first, entitlement: .tier1)
        StoreSubscription(.second, entitlement: .tier2)
    }
}

private func subscriptionSnapshot(
    id: UInt64,
    productID: String,
    subscriptionGroupID: String? = Plans.id.rawValue,
    productType: Product.ProductType = .autoRenewable,
    isUpgraded: Bool = false
) -> StoreTransactionSnapshot {
    let date = Date(timeIntervalSince1970: TimeInterval(id))

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
        purchaseDate: date,
        originalPurchaseDate: date,
        expirationDate: nil,
        revocationDate: nil,
        revocationReason: nil,
        purchasedQuantity: 1,
        isUpgraded: isUpgraded,
        ownershipType: .purchased,
        reason: .purchase,
        appAccountToken: nil,
        signedDate: date,
        jwsRepresentation: "catalog-jws-\(id)"
    )
}
