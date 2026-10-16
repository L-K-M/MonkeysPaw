// swift-tools-version: 6.0
// The server has no GLib loop and uses Swift 6 concurrency checking (D15).
import PackageDescription

let package = Package(
    name: "MonkeysPawServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonkeysPawServer", targets: ["MonkeysPawServer"]),
        .executable(name: "monkeyspaw-server", targets: ["monkeyspaw-server"]),
        .executable(name: "dump-schema", targets: ["dump-schema"]),
    ],
    dependencies: [
        // An explicit name keeps this reference stable in renamed worktrees.
        .package(name: "MonkeysPaw", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-fluent.git", exact: "2.0.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", exact: "4.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", exact: "2.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.1"),
    ],
    targets: [
        .target(
            name: "MonkeysPawServer",
            dependencies: [
                .product(name: "MonkeysPawCore", package: "MonkeysPaw"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdFluent", package: "hummingbird-fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "monkeyspaw-server",
            dependencies: [
                "MonkeysPawServer",
                .product(name: "MonkeysPawCore", package: "MonkeysPaw"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "dump-schema",
            dependencies: ["MonkeysPawServer"]
        ),
        // Test-only disk adapters are shared with the genuinely killed client.
        .target(
            name: "SyncScenarioSupport",
            dependencies: [.product(name: "MonkeysPawCore", package: "MonkeysPaw")],
            path: "Tests/MonkeysPawSyncIntegrationTests",
            exclude: ["InProcessHTTPTransport.swift", "ScenarioDecoder.swift", "SyncScenarioTests.swift",
                      "SyncServerHarness.swift", "SyncRestoreRetentionScenarioTests.swift", "SyncCrashScenarioTests.swift",
                      "SyncConflictMoveScenarioTests.swift", "SyncGroupScenarioTests.swift"],
            sources: ["ScenarioAdapters.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SyncCrashWorker",
            dependencies: [
                "SyncScenarioSupport",
                .product(name: "MonkeysPawCore", package: "MonkeysPaw"),
            ],
            path: "Tests/SyncCrashWorker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MonkeysPawServerTests",
            dependencies: [
                "MonkeysPawServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "MonkeysPawSyncIntegrationTests",
            dependencies: [
                "SyncScenarioSupport", "SyncCrashWorker",
                "MonkeysPawServer",
                .product(name: "MonkeysPawCore", package: "MonkeysPaw"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            exclude: ["ScenarioAdapters.swift"],
            // Client services use the desktop's Swift 5 language mode (E34).
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
