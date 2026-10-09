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
        // Reviewed 6.2.2 backport; Core rejects anchors before key comparison.
        // Fork provenance and the required parser lifetime are recorded in §3/§5.
        .package(url: "https://github.com/BigBoyDevBox/Yams.git",
                 revision: "d03c783ece4eeacf132828ff569c4060b4d4f198"),
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
// The GTK front end and executable exist only on Linux. Keeping them outside
// Core's dependency closure lets the server build without GTK headers and
// Xcode resolve the package on macOS.
package.targets.append(
    .systemLibrary(
        name: "CGtk",
        path: "Sources/CGtk",
        pkgConfig: "gtk4",
        providers: [.apt(["libgtk-4-dev"])]
    )
)
package.targets.append(
    .target(
        name: "MonkeysPawLinux",
        dependencies: ["MonkeysPawCore", "CGtk"],
        path: "Sources/MonkeysPawLinux"
    )
)
package.targets.append(
    .executableTarget(
        name: "monkeyspaw",
        dependencies: ["MonkeysPawLinux"],
        path: "Sources/monkeyspaw"
    )
)
package.products.append(
    .executable(name: "monkeyspaw", targets: ["monkeyspaw"])
)
package.targets.append(
    .testTarget(
        name: "MonkeysPawLinuxTests",
        dependencies: ["MonkeysPawLinux", "MonkeysPawCore", "CGtk"],
        path: "Tests/MonkeysPawLinuxTests"
    )
)
#endif
