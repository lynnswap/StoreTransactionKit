import StoreTransactionKit

private enum EntitlementID: String, Hashable, Sendable {
    case premium = "com.example.premium"
}

@main
@MainActor
struct Consumer {
    static func main() async throws {
        let store = Store<EntitlementID>(
            handleTransaction: { transaction in
                print("Handle transaction \(transaction.id)")
            },
            reportFailure: { failure in
                print("Background failure from \(failure.source)")
            }
        )

        if let activeEntitlements = store.activeEntitlements {
            print("Active entitlements: \(activeEntitlements)")
        } else {
            print("Active entitlements are unresolved")
        }
        try await store.close()
    }
}
