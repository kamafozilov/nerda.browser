import Foundation
import os

/// Where Nerda logs what went wrong: one category for each store, under
/// the app's own bundle id, so a development build's stay apart from the
/// released one's (`log show --predicate 'subsystem == "dev.nerda.browser"'`).
/// Paths, addresses and errors, which name files, are logged private: the
/// log is kept, and shared in a bug report.
nonisolated extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.nerda.browser"

    static let autoFill = Logger(subsystem: subsystem, category: "autofill")
    static let blocker = Logger(subsystem: subsystem, category: "blocker")
    static let bookmarks = Logger(subsystem: subsystem, category: "bookmarks")
    static let extensions = Logger(subsystem: subsystem, category: "extensions")
    static let history = Logger(subsystem: subsystem, category: "history")
    static let passwords = Logger(subsystem: subsystem, category: "passwords")
    static let profiles = Logger(subsystem: subsystem, category: "profiles")
    static let session = Logger(subsystem: subsystem, category: "session")
}
