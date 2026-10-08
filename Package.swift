// swift-tools-version: 5.9
//
// Monkey's Paw builds two ways: Xcode links the local MonkeysPawCore package
// product on macOS; Linux builds Core and its native front end with SwiftPM.
// The server also links Core through its own package, without GTK dependencies.
//
// Tools version 5.9 selects Swift 5 language mode, matching the desktop Xcode
// setting (D15). The Linux toolchain is Swift 6.4; the server uses Swift 6 mode.
import PackageDescription

let package = Package(
    name: "MonkeysPaw",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonkeysPawCore", targets: ["MonkeysPawCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "MonkeysPawCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            path: "Sources/MonkeysPawCore"
        ),
        .testTarget(
            name: "MonkeysPawCoreTests",
            dependencies: ["MonkeysPawCore", .product(name: "Yams", package: "Yams")],
            path: "Tests/MonkeysPawCoreTests"
        ),
    ]
)

#if os(Linux)
// M0b adds the CGtk system library, MonkeysPawLinux target, and monkeyspaw
// executable here. Keeping them outside Core's dependency closure lets the
// server build without GTK headers and Xcode resolve the package on macOS.
#endif
