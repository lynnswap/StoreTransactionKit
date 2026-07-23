# StoreKit Integration Tests

The app host gives StoreKit Test a real application process while testing the
public `TransactionStore` API from an external target. `StoreKitTest.storekit`
defines Tier 1 and Tier 2 as two service levels in the same subscription group,
with monthly and yearly products for each level. A test-only subscription in a
different group exercises delegate handling outside that catalog.

The serialized suite covers:

- direct purchases and external `Transaction.updates` handling through finish
- launch reconciliation for every monthly and yearly catalog product
- launch reconciliation for cancelled-active and already-expired subscriptions
- unfinished purchase replay until durable handling succeeds and finishes it
- interrupted purchases that resume through `Transaction.updates`
- verification failures that are reported and remain unfinished
- immediate Tier 1-to-Tier 2 upgrades
- Tier 2-to-Tier 1 downgrades at renewal
- cancellation remaining entitled until explicit expiration
- renewal transaction lineage and durable handling before status publication
- refunds
- empty, existing-entitlement, and failed restores
- Ask to Buy decline on pre-27 runtimes and approval on OS 27 and later

The host app and test bundle support iOS, tvOS, watchOS, and visionOS. Run the
StoreKit runtime suite on an installed iOS Simulator. StoreKit Test owns one
environment per process, so parallel test execution must remain disabled.

```sh
xcodebuild test \
  -workspace Tools/TestApp/StoreTransactionKitTestApp.xcworkspace \
  -scheme StoreTransactionKitIntegrationTests \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -parallel-testing-enabled NO
```

Cross-build the complete app-hosted test bundle for the additional platforms:

```sh
for destination in \
  'generic/platform=tvOS Simulator' \
  'generic/platform=watchOS Simulator' \
  'generic/platform=visionOS Simulator'
do
  xcodebuild build-for-testing \
    -workspace Tools/TestApp/StoreTransactionKitTestApp.xcworkspace \
    -scheme StoreTransactionKitIntegrationTests \
    -destination "$destination" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
done
```

The tests wait for observable state changes with cancellation-aware event
signals. They don't use fixed sleeps or accelerated wall-clock time. A suite
time limit exists only to surface a missing event as a failed test instead of
hanging the test process.

The external-update test covers an unmanaged delegate `.finish` on every
runtime with the test-only subscription group. The raw projection retains that
transaction while the typed catalog projection remains empty. On iOS 18.6,
StoreKit Test's automatic causal and startup queries can resolve before its
current-entitlement view updates. That lane verifies initial handling before an
explicit refresh exposes the raw transaction, then uses a new store to prove
there is no unfinished replay before refreshing its raw projection.

Ask to Buy decline isn't automated on iOS 27 because StoreKit Test produces a
purchased transaction after `declineAskToBuyTransaction(identifier:)`. The
suite validates decline on pre-27 runtimes and pending-to-approved delivery on
OS 27 and later. Validate the iOS 27 decline path separately in Sandbox.

Two other iOS 27 StoreKit Test differences have explicit test boundaries.
Expiring a subscription doesn't publish a subscription-status update, so that
lane performs a restore before asserting removal. An injected `AppStore.sync`
network failure arrives as `StoreKitError.systemError` with an unknown internal
error instead of the typed network error delivered on pre-27 runtimes.

CI runs this suite with Xcode 26.5 on the iOS 26.2 simulator available in the
GitHub macOS 26 image. CI also cross-builds the app host and test bundle for
tvOS, watchOS, and visionOS simulators. The same runtime suite is validated
locally with Xcode 26.5 on iOS 18.6 to cover the supported iOS 18 line.

Local StoreKit testing doesn't validate App Store Connect configuration,
App Store Server Notifications, cross-device propagation, Family Sharing or
Ask to Buy with real accounts, offer eligibility, or the production purchase
and restore sheets. Validate those boundaries separately in Sandbox before
release. Billing retry and grace-period transitions also remain Sandbox
scenarios because the StoreKit query doesn't complete reliably after forcing a
billing failure with Xcode 26.5 on the supported iOS 18.6 runtime.
