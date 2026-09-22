// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeMeter", targets: ["ClaudeMeter"]),
    ],
    targets: [
        // Foundation-only logic: credentials, API client, parsing, thresholds, formatting.
        .target(name: "ClaudeMeterCore"),
        // SwiftUI/AppKit menu bar app.
        .executableTarget(name: "ClaudeMeter", dependencies: ["ClaudeMeterCore"]),
        .testTarget(name: "ClaudeMeterCoreTests", dependencies: ["ClaudeMeterCore"]),
    ]
)
