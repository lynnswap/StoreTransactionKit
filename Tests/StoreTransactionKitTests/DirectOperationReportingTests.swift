import Testing
@testable import StoreTransactionKit

@Suite("Direct operation reporting authority")
struct DirectOperationReportingTests {
    @Test("an attached caller receives the failure without a background report")
    func attachedCallerOwnsFailureDelivery() throws {
        let authority = DirectOperationReportingAuthority()
        let owner = DirectOperationObservation()
        let observer = DirectOperationObservation()
        let ownerBinding = owner.bind(to: authority)
        let observerBinding = observer.bind(to: authority)

        #expect(owner.abandon() == nil)
        #expect(
            owner.fail(ownerBinding, report: makeReport(id: 1)) == nil
        )
        #expect(observer.fail(observerBinding, report: nil) == nil)
        observer.deliver()

        #expect(owner.abandon() == nil)
    }

    @Test("the last abandoned caller claims the physical owner's report once")
    func lastAbandonedCallerClaimsOwnerReport() throws {
        let authority = DirectOperationReportingAuthority()
        let owner = DirectOperationObservation()
        let observer = DirectOperationObservation()
        let ownerBinding = owner.bind(to: authority)
        let observerBinding = observer.bind(to: authority)

        #expect(
            owner.fail(ownerBinding, report: makeReport(id: 2)) == nil
        )
        #expect(observer.fail(observerBinding, report: nil) == nil)
        #expect(owner.abandon() == nil)
        let claimed = observer.abandon()

        #expect(
            claimed?.source
                == .abandonedDirectOperation(.currentEntitlements)
        )
        #expect(claimed?.transactionID == 2)
        #expect(claimed?.underlyingError is TestFailure)
        #expect(observer.abandon() == nil)
    }

    @Test("a failure claims once when every caller abandoned before completion")
    func failureAfterEveryCallerAbandons() throws {
        let authority = DirectOperationReportingAuthority()
        let owner = DirectOperationObservation()
        let observer = DirectOperationObservation()
        let ownerBinding = owner.bind(to: authority)
        let observerBinding = observer.bind(to: authority)

        #expect(owner.abandon() == nil)
        #expect(observer.abandon() == nil)
        #expect(observer.fail(observerBinding, report: nil) == nil)
        let claimed = owner.fail(ownerBinding, report: makeReport(id: 3))

        #expect(claimed?.transactionID == 3)
        #expect(owner.fail(ownerBinding, report: makeReport(id: 3)) == nil)
    }

    private func makeReport(id: UInt64) -> StoreTransactionBackgroundFailure {
        StoreTransactionBackgroundFailure(
            source: .abandonedDirectOperation(.currentEntitlements),
            transactionID: id,
            productID: "product-\(id)",
            underlyingError: TestFailure()
        )
    }
}
