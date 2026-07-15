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

        print("Active entitlements: \(store.activeEntitlements)")
        try await store.close()
    }
}
