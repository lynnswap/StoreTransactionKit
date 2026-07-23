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
        #expect(
            catalog.productIDs
                == [CountingPlans.ProductID.monthly.rawValue]
        )
        #expect(catalog.isDeclared(by: CountingPlans.self))
        #expect(!catalog.isDeclared(by: OtherPlans.self))
        #expect(catalog.contains(productID: CountingPlans.ProductID.monthly.rawValue))
        #expect(!catalog.contains(productID: "com.example.subscription.undeclared"))
        #expect(
            catalog.entitlement(
                for: CountingPlans.ProductID.monthly.rawValue
            ) == .tier1
        )
        #expect(
            catalog.entitlement(
                for: "com.example.subscription.undeclared"
            ) == nil
        )

        let transaction = subscriptionSnapshot(
            id: 0,
            productID: CountingPlans.ProductID.monthly.rawValue,
            subscriptionGroupID: CountingPlans.id.rawValue
        )
        #expect(
            try catalog.classification(of: transaction)
                == .declared(.tier1)
        )
        #expect(countingSubscriptionsAccessCount.withLock { $0 } == 1)
    }

    @Test("monthly and yearly products classify with their declared entitlements")
    func classifiesDeclaredEntitlements() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        #expect(
            catalog.productIDs
                == [
                    Plans.ProductID.tier1_Monthly.rawValue,
                    Plans.ProductID.tier1_Yearly.rawValue,
                    Plans.ProductID.tier2_Monthly.rawValue,
                    Plans.ProductID.tier2_Yearly.rawValue,
                ]
        )
        let classifications = try [
            Plans.ProductID.tier1_Monthly,
            .tier1_Yearly,
            .tier2_Monthly,
            .tier2_Yearly,
        ].enumerated().map { offset, productID in
            try catalog.classification(
                of: subscriptionSnapshot(
                    id: UInt64(offset + 1),
                    productID: productID.rawValue
                )
            )
        }

        #expect(
            classifications == [
                .declared(.tier1),
                .declared(.tier1),
                .declared(.tier2),
                .declared(.tier2),
            ]
        )
    }

    @Test("optional entitlement values remain declared")
    func optionalEntitlementRemainsDeclared() throws {
        let catalog = AutoRenewableSubscriptionCatalog(OptionalPlans.self)
        let productID = OptionalPlans.ProductID.monthly.rawValue

        #expect(catalog.productIDs == [productID])
        #expect(catalog.entitlement(for: productID) == .some(nil))
        #expect(catalog.contains(productID: productID))
        #expect(
            try catalog.classification(
                of: subscriptionSnapshot(
                    id: 4,
                    productID: productID,
                    subscriptionGroupID: OptionalPlans.id.rawValue
                )
            ) == .declared(nil)
        )
    }

    @Test("an upgraded declared product remains declared")
    func upgradedDeclaredProductRemainsDeclared() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let transaction = subscriptionSnapshot(
            id: 5,
            productID: Plans.ProductID.tier1_Monthly.rawValue,
            isUpgraded: true
        )

        #expect(
            try catalog.classification(of: transaction)
                == .declared(.tier1)
        )
    }

    @Test("a retired upgraded product has a non-projecting classification")
    func retiredUpgradedProductIsClassified() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let transaction = subscriptionSnapshot(
            id: 6,
            productID: "com.example.subscription.retired",
            isUpgraded: true
        )

        #expect(
            try catalog.classification(of: transaction)
                == .retiredUpgraded
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
    }

    @Test("a declared product with a wrong StoreKit type fails validation")
    func declaredProductTypeMismatch() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = Plans.ProductID.tier1_Monthly.rawValue

        do {
            _ = try catalog.classification(
                of: subscriptionSnapshot(
                    id: 8,
                    productID: productID,
                    productType: .nonConsumable
                )
            )
            Issue.record("Classification unexpectedly accepted a non-consumable product.")
        } catch let error {
            guard case let .productTypeMismatch(actualProductID, actual) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }

            #expect(actualProductID == productID)
            #expect(actual == .nonConsumable)
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
        } catch let error {
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
        }
    }

    @Test("an undeclared current product in the managed group is unrecognized")
    func undeclaredCurrentProductIsUnrecognized() throws {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = "com.example.subscription.undeclared"

        #expect(
            try catalog.classification(
                of: subscriptionSnapshot(
                    id: 10,
                    productID: productID
                )
            ) == .unrecognized
        )
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
        } catch let error {
            guard case let .productTypeMismatch(actualProductID, actual) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }

            #expect(actualProductID == productID)
            #expect(actual == .nonRenewable)
        }
    }

    @Test("an unrecognized current product still requires an auto-renewable type")
    func unrecognizedProductTypeMismatch() {
        let catalog = AutoRenewableSubscriptionCatalog(Plans.self)
        let productID = "com.example.subscription.undeclared"

        do {
            _ = try catalog.classification(
                of: subscriptionSnapshot(
                    id: 12,
                    productID: productID,
                    productType: .nonRenewable
                )
            )
            Issue.record("Classification unexpectedly accepted the wrong type.")
        } catch let error {
            guard case let .productTypeMismatch(actualProductID, actual) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }
            #expect(actualProductID == productID)
            #expect(actual == .nonRenewable)
        }
    }

    #if os(macOS)
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
    #endif
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

private enum OptionalPlans:
    AutoRenewableSubscriptionGroup<SubscriptionEntitlement?>
{
    static let id = SubscriptionGroupID(rawValue: "optional-group")

    enum ProductID: String, Hashable, Sendable {
        case monthly = "com.example.optional.monthly"
    }

    static var subscriptions: StoreSubscriptions {
        StoreSubscription(.monthly, entitlement: nil)
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
