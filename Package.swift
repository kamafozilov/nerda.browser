// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nerda",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "Nerda",
            // The whole app lives on the main thread, like AppKit and WebKit
            // themselves; background work opts out explicitly.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "NerdaTests", dependencies: ["Nerda"]),
    ]
)
