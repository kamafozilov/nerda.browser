import AppKit
import os

/// A launch of Nerda an agent's nerda-browser asked for, with Nerda closed
/// (`AgentLauncher.hiddenArgument`): no window, no Dock tile, not made
/// active. It quits once agents leave it idle for 30 minutes, unless the
/// owner opens Nerda first: that shows its window as any launch does, and
/// it stays.
///
/// Nerda never hides itself as an app (`NSApp.hide`): WebKit takes a hidden
/// app's pages as out of sight, Agent tabs' among them.
@MainActor
final class HiddenStart {
    /// This launch's, when it started hidden (main.swift).
    static var shared: HiddenStart?

    static let idleLimit: Duration = .seconds(30 * 60)

    /// Hidden still: the owner hasn't opened Nerda since it started.
    private(set) var isHidden = true

    private let server: AgentServer
    private let idleLimit: Duration
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private let show: () -> Void
    private let quit: () -> Void
    private let began = ContinuousClock.now
    private var idleWatch: Task<Void, Never>?

    /// Starts hidden: `setPolicy` sets the app's activation policy, `show`
    /// opens the windows a launch opens with, `quit` quits without asking.
    init(server: AgentServer, idleLimit: Duration = HiddenStart.idleLimit,
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
         show: @escaping () -> Void, quit: @escaping () -> Void) {
        self.server = server
        self.idleLimit = idleLimit
        self.setPolicy = setPolicy
        self.show = show
        self.quit = quit
        // No Dock tile and no menu bar, yet it can still be made active,
        // as opening it by hand does.
        setPolicy(.accessory)
        watchIdle()
    }

    /// The owner opened Nerda (from Finder, the Dock, a link): from now on
    /// it is Nerda as any launch, with its window and Dock tile, and stays.
    func showWindow() {
        guard isHidden else { return }
        isHidden = false
        stop()
        setPolicy(.regular)
        show()
    }

    /// No more quitting idle.
    func stop() {
        idleWatch?.cancel()
        idleWatch = nil
    }

    private func watchIdle() {
        idleWatch = Task { [weak self] in
            while let wait = self?.untilIdle() {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self, isHidden else { return }
            Logger.agents.notice("Nerda, started hidden for agents, quits: idle")
            quit()
        }
    }

    /// How long until agents have left Nerda idle long enough; nil once they
    /// have, or when they may not use it at all.
    private func untilIdle() -> Duration? {
        guard server.isOn else { return nil }
        if server.working > 0 { return idleLimit }
        let idle = ContinuousClock.now - max(began, server.lastUsed ?? began)
        return idle >= idleLimit ? nil : idleLimit - idle
    }
}
