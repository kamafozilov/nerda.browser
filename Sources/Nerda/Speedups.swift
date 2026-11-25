import Foundation

/// The speed-ups of spec #118, each on unless its environment variable,
/// NERDA_ and its name, is "0" for this run, to time one build with it and
/// without it on the same Mac (Recorder.swift). Tests set `overrides`.
enum Speedups {
    /// Each switch, by the name its variable carries.
    enum Name: String {
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
        overrides[name] ?? (ProcessInfo.processInfo.environment["NERDA_" + name.rawValue] != "0")
    }
}
