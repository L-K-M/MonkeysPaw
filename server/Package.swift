// swift-tools-version: 6.0
// The server has no GLib loop and uses Swift 6 concurrency checking (D15).
import PackageDescription

let package = Package(
    name: "MonkeysPawServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonkeysPawServer", targets: ["MonkeysPawServer"]),
        .executable(name: "monkeyspaw-server", targets: ["monkeyspaw-server"]),
    ],
    dependencies: [
        // An explicit name keeps this reference stable in renamed worktrees.
        .package(name: "MonkeysPaw", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "MonkeysPawServer",
            dependencies: [
                .product(name: "MonkeysPawCore", package: "MonkeysPaw"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "monkeyspaw-server",
            dependencies: [
                "MonkeysPawServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MonkeysPawServerTests",
            dependencies: [
                "MonkeysPawServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
