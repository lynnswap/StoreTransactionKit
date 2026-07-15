// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "StoreTransactionKitExternalConsumer",
    platforms: [
        .iOS("18.4"),
        .macOS("15.4"),
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(
                    name: "StoreTransactionKit",
                    package: "StoreTransactionKit"
                )
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        )
    ]
)
