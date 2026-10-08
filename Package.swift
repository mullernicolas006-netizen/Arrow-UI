// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveUI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LiveUIModels", targets: ["LiveUIModels"]),
        .library(name: "LiveUICore", targets: ["LiveUICore"]),
        .library(name: "SimulatorBridge", targets: ["SimulatorBridge"]),
        .library(name: "LiveUIRuntime", targets: ["LiveUIRuntime"]),
        .executable(name: "LiveUIApp", targets: ["LiveUIApp"])
    ],
    dependencies: [
        // Structural Swift source parsing + rewriting for the Code Mutation Engine (§11-13).
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0")
    ],
    targets: [
        // Plain data model shared by every other target: view identity, the
        // Mutation model, and the wire protocol between runtime and app.
        // Deliberately has zero platform-specific imports so it builds
        // anywhere (including plain `swift build` on Linux).
        .target(
            name: "LiveUIModels"
        ),

        // SourceIndexer, SwiftSyntaxEngine, MutationEngine, LayoutEngine,
        // HistoryEngine, Diagnostics — the "brain" of LiveUI (§46-55).
        // Also platform-agnostic; this is the part of the product that is
        // realistically unit-testable without Xcode.
        .target(
            name: "LiveUICore",
            dependencies: [
                "LiveUIModels",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),

        // Local TCP transport + framing between a running app (Simulator)
        // and the LiveUI desktop app (§7, §50, §56).
        .target(
            name: "SimulatorBridge",
            dependencies: ["LiveUIModels"]
        ),

        // Runs *inside* the app under development. View tagging + geometry
        // reporting (§7-8). Depends on SimulatorBridge for the client side
        // of the transport.
        .target(
            name: "LiveUIRuntime",
            dependencies: ["SimulatorBridge", "LiveUIModels"]
        ),

        // The macOS LiveUI application shell (§6.1). A SwiftUI app run via
        // SwiftPM (`swift run LiveUIApp`) rather than a hand-built .xcodeproj,
        // so the whole monorepo builds with one `swift build`.
        .executableTarget(
            name: "LiveUIApp",
            dependencies: ["LiveUICore", "SimulatorBridge", "LiveUIModels"]
        ),

        .testTarget(
            name: "LiveUICoreTests",
            dependencies: ["LiveUICore", "LiveUIModels"]
        )
    ]
)
