import Foundation

/// The speed-ups of spec #118, each on unless its environment variable,
/// NERDA_ and its name, is "0" for this run, to time one build with it and
/// without it on the same Mac (Recorder.swift). Tests set `overrides`, or
/// the switch of their own record or window where there is one
/// (`Recorder.switchedOn`, `Browser.lastFramesOn`).
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
        overrides[name] ?? environment[name] ?? true
    }

    /// The switches the run's environment sets, read once: the environment is copied whole each
    /// time it is asked for, some 25 µs, and the recorder asks at every
    /// timing.
    private static let environment: [Name: Bool] = {
        let variables = ProcessInfo.processInfo.environment
        return Dictionary(uniqueKeysWithValues: Name.allCases.compactMap { name in
            variables["NERDA_" + name.rawValue].map { (name, $0 != "0") }
        })
    }()
}
