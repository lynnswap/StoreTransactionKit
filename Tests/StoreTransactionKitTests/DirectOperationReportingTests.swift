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
                == .abandonedDirectOperation(.refreshEntitlements)
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

    @Test("merged physical owners select one background report")
    func mergedAuthoritiesReportOnce() throws {
        let processAuthority = DirectOperationReportingAuthority()
        let refreshAuthority = DirectOperationReportingAuthority()
        let process = DirectOperationObservation()
        let refresh = DirectOperationObservation()
        let processBinding = process.bind(to: processAuthority)
        let refreshBinding = refresh.bind(to: refreshAuthority)
        processAuthority.merge(into: refreshAuthority)

        #expect(process.abandon() == nil)
        #expect(refresh.abandon() == nil)
        let claimed = process.fail(
            processBinding,
            report: makeReport(id: 4)
        )
        let duplicate = refresh.fail(
            refreshBinding,
            report: makeReport(id: 5)
        )

        #expect(claimed?.transactionID == 4)
        #expect(duplicate == nil)
    }

    private func makeReport(id: UInt64) -> StoreTransactionBackgroundFailure {
        StoreTransactionBackgroundFailure(
            source: .abandonedDirectOperation(.refreshEntitlements),
            transactionID: id,
            productID: "product-\(id)",
            underlyingError: TestFailure()
        )
    }
}
