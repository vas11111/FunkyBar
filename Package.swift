// swift-tools-version: 6.0
import PackageDescription

// Tests are an executable rather than a .testTarget on purpose: XCTest and
// swift-testing both ship inside Xcode, and this project targets a machine
// with Command Line Tools only. `swift run funkybar-test` works everywhere.
// See Sources/TestKit.

let package = Package(
    name: "funkybar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "funkybar", targets: ["funkybar"]),
        .executable(name: "funkybard", targets: ["FunkyBarDaemon"]),
        .executable(name: "funkybar-test", targets: ["FunkyBarTests"]),
        .executable(name: "funkybar-measure", targets: ["funkybar-measure"]),
        .library(name: "FunkyBarCore", targets: ["FunkyBarCore"]),
    ],
    targets: [
        // Pure model, config, and layout. No AppKit, no I/O. Testable headlessly.
        .target(name: "FunkyBarCore"),

        // Wire protocol and non-blocking unix-socket transport.
        .target(name: "FunkyBarIPC", dependencies: ["FunkyBarCore"]),

        // State sources. Native first, subprocess only as an escape hatch.
        .target(name: "FunkyBarProviders", dependencies: ["FunkyBarCore"]),

        // NSPanel host and the CALayer tree.
        .target(name: "FunkyBarRender", dependencies: ["FunkyBarCore"]),

        // The daemon.
        .executableTarget(
            name: "FunkyBarDaemon",
            dependencies: ["FunkyBarCore", "FunkyBarIPC", "FunkyBarProviders", "FunkyBarRender"]
        ),

        // The thin CLI client.
        .executableTarget(name: "funkybar", dependencies: ["FunkyBarCore", "FunkyBarIPC"]),

        // Compares on-screen geometry against sketchybar's, item by item.
        .executableTarget(name: "funkybar-measure"),

        // Test harness and the suites that use it.
        .target(name: "TestKit"),
        .executableTarget(
            name: "FunkyBarTests",
            dependencies: ["TestKit", "FunkyBarCore", "FunkyBarIPC", "FunkyBarProviders", "FunkyBarRender"]
        ),
    ]
)
