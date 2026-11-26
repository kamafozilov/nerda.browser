import Foundation

/// The speed-ups of spec #118, each on unless its environment variable,
/// NERDA_ and its name, is "0" for this run, to time one build with it and
/// without it on the same Mac (Recorder.swift). Tests set `overrides`.
enum Speedups {
    /// Each switch, by the name its variable carries.
    enum Name: String, CaseIterable {
        case sparePage = "SPARE_PAGE"
        case hiddenRun = "HIDDEN_RUN"
        case lastFrame = "LAST_FRAME"
        case pressurePolicy = "PRESSURE_POLICY"
        case hangHandling = "HANG_HANDLING"
        case recorder = "RECORDER"
        case launchLater = "LAUNCH_LATER"
    }

    static var overrides: [Name: Bool] = [:]

    static func isOn(_ name: Name) -> Bool {
        overrides[name] ?? set[name] ?? true
    }

    /// The run's variables, read once: the environment is copied whole each
    /// time it is asked for, some 25 µs, and the recorder asks at every
    /// timing.
    private static let set: [Name: Bool] = {
        let environment = ProcessInfo.processInfo.environment
        return Dictionary(uniqueKeysWithValues: Name.allCases.compactMap { name in
            environment["NERDA_" + name.rawValue].map { (name, $0 != "0") }
        })
    }()
}
