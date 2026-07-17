// swift-tools-version: 6.3

import PackageDescription

private let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "StoreTransactionKit",
    platforms: [
        .iOS("18.4"),
        .macCatalyst("18.4"),
        .macOS("15.4"),
        .tvOS("18.4"),
        .watchOS("11.4"),
        .visionOS("2.4"),
    ],
    products: [
        .library(
            name: "StoreTransactionKit",
            targets: ["StoreTransactionKit"]
        )
    ],
    targets: [
        .target(
            name: "StoreTransactionKit",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "StoreTransactionKitTests",
            dependencies: ["StoreTransactionKit"],
            swiftSettings: strictSwiftSettings
        ),
    ]
)
