import AppKit
import os

/// How the shim (`AgentMCP`) and the command (`AgentCommandLine`) start
/// Nerda when an agent calls and nothing answers on the socket
/// (`AgentWire.send`): hidden, in the background (`HiddenStart`), never
/// made active, never shown, never hidden as an app. Running already, with
/// agents turned off, it is left as it is: opening it again would bring its
/// window back.
///
/// Tests pass a launcher of their own: the real one starts the real app.
nonisolated struct AgentLauncher: Sendable {
    /// What the shim finds of the app.
    enum App: Sendable {
        /// Not running: the shim starts it.
        case closed
        /// On its way up: its socket is soon there.
        case starting
        /// Running and up. Its socket not answering means agents are off.
        case open
    }

    /// The launch argument that starts Nerda hidden.
    static let hiddenArgument = "--hidden-for-agents"

    /// Whether Nerda is running.
    var app: @Sendable () -> App
    /// Starts Nerda hidden.
    var open: @Sendable () async throws -> Void
    /// How long a Nerda started has to answer.
    var wait: Duration = .seconds(20)
    /// How often the shim looks again meanwhile.
    var poll: Duration = .milliseconds(100)

    /// The app the shim is the binary of, when it runs from one: a release
    /// or development build's, never a test run's.
    static var thisApp: AgentLauncher? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let id = bundle.bundleIdentifier else { return nil }
        return app(at: bundle.bundleURL, id: id)
    }

    /// The app at `url`, its bundle id `id`.
    static func app(at url: URL, id: String) -> AgentLauncher {
        AgentLauncher(
            app: {
                // The app's own process, not shims (they never make an
                // NSApplication, so macOS doesn't list them), nor this one.
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
                guard !running.isEmpty else { return .closed }
                return running.allSatisfy(\.isFinishedLaunching) ? .open : .starting
            },
            open: {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        )
    }

    /// In the background, not made active, with the hidden-start argument,
    /// and not among the recent items. Not `hides`: WebKit takes a hidden
    /// app's pages as out of sight.
    static var configuration: NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        configuration.arguments = [hiddenArgument]
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return configuration
    }

    /// Whether Nerda is (or soon will be) up for the shim to try again:
    /// started now if it was closed. False when it is open already, so its
    /// socket not answering is its Settings, or when it couldn't be started.
    func started() async -> Bool {
        switch app() {
        case .open:
            return false
        case .starting:
            return true
        case .closed:
            do {
                try await open()
                return true
            } catch {
                Logger.agents.error("Nerda couldn't be started for an agent: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }
}
