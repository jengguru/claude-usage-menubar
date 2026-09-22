// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
    ],
    targets: [
        // Foundation-only logic: credentials, API client, parsing, thresholds, formatting.
        .target(name: "HeadroomCore"),
        // SwiftUI/AppKit menu bar app.
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
