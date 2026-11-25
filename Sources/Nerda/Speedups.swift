import Foundation

/// The speed-ups of spec #118, each on unless its environment variable,
/// NERDA_ and its name, is "0" for this run, to time one build with it and
/// without it on the same Mac (Recorder.swift). Tests set `overrides`.
enum Speedups {
    static var overrides: [String: Bool] = [:]

    static func isOn(_ name: String) -> Bool {
        overrides[name] ?? (ProcessInfo.processInfo.environment["NERDA_" + name] != "0")
    }
}
