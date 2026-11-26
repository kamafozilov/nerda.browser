import Foundation

/// Which Nerda this is. A development build (`./build.sh debug`, `./watch.sh`)
/// is a second app beside the released one: its own name and bundle id
/// (build.sh), data folder and keychain item, so working on Nerda never
/// touches the tabs, history and passwords of the Nerda in use. Only a
/// release build updates itself.
nonisolated enum Edition {
    /// Running in the tests (`swift test`, Xcode), not in an app: SwiftPM runs
    /// them in a helper without a bundle id, and every test runner loads
    /// XCTest, which no Nerda does. The tests are then an edition of their
    /// own, with a name and a folder of their run, so a test never reads or
    /// writes the tabs, history or passwords of a Nerda on this Mac.
    static let testing = Bundle.main.bundleIdentifier == nil || NSClassFromString("XCTestCase") != nil

    #if DEBUG
    /// Nerda Test (`./build.sh test`) is a development build too, with data
    /// of its own.
    static let name = if testing { "Nerda Tests" } else {
        switch Bundle.main.bundleIdentifier {
        case "dev.nerda.browser.test": "Nerda Test"
        default: "Nerda Dev"
        }
    }
    /// Whether it checks for and installs newer releases (Updater.swift).
    static let updates = false
    #else
    static let name = testing ? "Nerda Tests" : "Nerda"
    static let updates = !testing
    #endif

    /// Where the tabs, history, icons and account names are kept. The
    /// tests' is new for each run, in the temporary folder, its name short
    /// enough for the agents' socket in it (`AgentWire.socket`).
    static let folder = testing
        ? URL.temporaryDirectory.appending(path: "Nerda Tests \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        : URL.applicationSupportDirectory.appending(path: name)

    /// Where downloads go unless another folder is chosen (`Downloads.folder`):
    /// the tests' stay in their folder.
    static let downloads = testing ? folder.appending(path: "Downloads", directoryHint: .isDirectory) : URL.downloadsDirectory
}
