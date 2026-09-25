import Foundation

/// Which Nerda this is. A development build (`./build.sh debug`, `./watch.sh`)
/// is a second app beside the released one: its own name and bundle id
/// (build.sh), data folder and keychain item, so working on Nerda never
/// touches the tabs, history and passwords of the Nerda in use. Only a
/// release build updates itself.
nonisolated enum Edition {
    #if DEBUG
    /// Nerda Bench (`./build.sh bench`) is a development build too, with data of its own.
    static let name = Bundle.main.bundleIdentifier == "dev.nerda.browser.bench" ? "Nerda Bench" : "Nerda Dev"
    /// Whether it checks for and installs newer releases (Updater.swift).
    static let updates = false
    #else
    static let name = "Nerda"
    static let updates = true
    #endif

    /// Where the tabs, history, icons and account names are kept.
    static let folder = URL.applicationSupportDirectory.appending(path: name)
}
