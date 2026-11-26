// swift-tools-version: 6.2
import PackageDescription

/// Swift 6.2's approachable concurrency: a `nonisolated` async function runs
/// where it is called from, not on the global pool, unless it is marked
/// `@concurrent`; a main-actor type's conformances are main-actor too.
let approachable: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "Nerda",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "Nerda",
            // The whole app lives on the main thread, like AppKit and WebKit
            // themselves; background work opts out explicitly.
            swiftSettings: [.defaultIsolation(MainActor.self)] + approachable
        ),
        // How the test run itself goes: how many tests run at once (TestRun.c).
        .target(name: "TestRun", path: "Tests/TestRun"),
        // The sound a page played: the sweep it plays, its recording with the
        // system's process tap and their comparison. Apart from the tests so
        // that a lab run outside `swift test` can record and compare too.
        .target(name: "SoundCheck", path: "Tests/SoundCheck", swiftSettings: approachable),
        .testTarget(name: "NerdaTests", dependencies: ["Nerda", "TestRun", "SoundCheck"], swiftSettings: approachable),
    ]
)
