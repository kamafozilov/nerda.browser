import AppKit
import Foundation
import os
import Testing
@testable import Nerda

/// Nerda started hidden when an agent needs it (#133): the shim starting it
/// when nothing answers, and the hidden launch's life after. Never the real
/// Nerda: a stand-in launcher starts the test's own agent server, and the
/// hidden launch's app (its Dock tile, showing, quitting) is a stand-in too.
@MainActor
struct HiddenStartTests {
    // MARK: The shim starting Nerda

    @Test func anAgentCallWithNerdaClosedStartsItHiddenAndSucceeds() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/news", "<title>News</title><p>Fresh today</p>")
        // Nerda closed: nothing listens on its socket.
        harness.server.stop()
        let nerda = StandInNerda(server: harness.server)
        let agent = try await harness.agent(launcher: nerda.launcher())

        // Two calls at once: one start of Nerda for both.
        async let opened = agent.call("open", ["url": AgentJSON(url)])
        async let listed = agent.call("tabs")
        let (open, tabs) = try await (opened, listed)

        #expect(!open.isError, "\(open.text)")
        #expect(open.text.contains("Fresh today"))
        #expect(!tabs.isError, "\(tabs.text)")
        #expect(nerda.opens == 1)
    }

    @Test func nerdaIsStartedWithoutComingForwardOrAWindow() {
        let configuration = AgentLauncher.configuration
        #expect(configuration.activates == false)
        #expect(configuration.hides == false)
        #expect(configuration.arguments == [AgentLauncher.hiddenArgument])
        #expect(configuration.addsToRecentItems == false)
    }

    @Test func withNerdaOpenAndAgentsTurnedOffTheAgentIsToldAtOnce() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.stop()
        let nerda = StandInNerda(server: harness.server, app: .open)
        let agent = try await harness.agent(launcher: nerda.launcher())

        let clock = ContinuousClock()
        let began = clock.now
        let answer = try await agent.call("tabs")

        #expect(answer.isError)
        #expect(answer.text.contains("turned off"), "\(answer.text)")
        #expect(clock.now - began < .seconds(2))
        #expect(nerda.opens == 0)
    }

    @Test func aStartThatNeverAnswersTellsTheAgentToAskTheUser() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.stop()
        let nerda = StandInNerda(server: harness.server, startsListening: false)
        let agent = try await harness.agent(launcher: nerda.launcher(wait: .milliseconds(500)))

        let answer = try await agent.call("tabs")

        #expect(answer.isError)
        #expect(answer.text.contains("Ask the user to open Nerda"), "\(answer.text)")
        #expect(nerda.opens == 1)
    }

    // MARK: The hidden launch

    @Test func aHiddenStartHasNoDockTileAndQuitsOnceAgentsLeaveItIdle() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let app = StandInApp()
        // Long enough that a busy test machine's pauses between calls don't
        // count as an agent leaving it.
        let idleLimit = Duration.seconds(3)
        let start = HiddenStart(server: harness.server, idleLimit: idleLimit,
                                setPolicy: app.setPolicy, show: app.show, quit: app.quit)
        defer { start.stop() }
        #expect(app.policies == [.accessory])

        // An agent at work keeps it running past its idle time.
        let agent = try await harness.agent()
        let clock = ContinuousClock()
        let working = clock.now
        while clock.now - working < idleLimit * 1.5 {
            #expect(try await !agent.call("tabs").isError)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(app.quits == 0)

        // Left alone, it quits, never having shown a window.
        try await waitFor(timeout: .seconds(10)) { app.quits == 1 }
        #expect(app.shows == 0)
        #expect(app.policies == [.accessory])
    }

    @Test func openingNerdaByHandShowsItsWindowAndKeepsItRunning() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let app = StandInApp()
        let start = HiddenStart(server: harness.server, idleLimit: .milliseconds(300),
                                setPolicy: app.setPolicy, show: app.show, quit: app.quit)
        defer { start.stop() }

        start.showWindow()
        start.showWindow()

        #expect(app.policies == [.accessory, .regular])
        #expect(app.shows == 1)
        #expect(!start.isHidden)
        try await Task.sleep(for: .milliseconds(800))
        #expect(app.quits == 0)
    }

    @Test func aHiddenStartWithAgentsTurnedOffQuitsAtOnce() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.defaults.set(false, forKey: AgentServer.isOnKey)
        let app = StandInApp()
        let start = HiddenStart(server: harness.server, idleLimit: .seconds(60),
                                setPolicy: app.setPolicy, show: app.show, quit: app.quit)
        defer { start.stop() }

        try await waitFor(timeout: .seconds(2)) { app.quits == 1 }
        #expect(app.shows == 0)
    }
}

/// Nerda as the shim's launcher sees it, without starting any real app:
/// closed until opened, then starting until its server (the test's own)
/// listens a moment later.
private final class StandInNerda: Sendable {
    private struct State {
        var app: AgentLauncher.App
        var opens = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let server: AgentServer
    private let startsListening: Bool

    init(server: AgentServer, app: AgentLauncher.App = .closed, startsListening: Bool = true) {
        self.server = server
        self.startsListening = startsListening
        state = OSAllocatedUnfairLock(initialState: State(app: app))
    }

    var opens: Int { state.withLock(\.opens) }

    func launcher(wait: Duration = .seconds(10)) -> AgentLauncher {
        AgentLauncher(app: { self.state.withLock(\.app) }, open: { await self.open() },
                      wait: wait, poll: .milliseconds(50))
    }

    private func open() async {
        state.withLock {
            $0.opens += 1
            $0.app = .starting
        }
        guard startsListening else { return }
        let server = server
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            server.start()
            self.state.withLock { $0.app = .open }
        }
    }
}

/// What a hidden launch does to the app, kept rather than done: tests never
/// change the test process's Dock tile, show windows or quit.
@MainActor
private final class StandInApp {
    private(set) var policies: [NSApplication.ActivationPolicy] = []
    private(set) var shows = 0
    private(set) var quits = 0

    func setPolicy(_ policy: NSApplication.ActivationPolicy) { policies.append(policy) }
    func show() { shows += 1 }
    func quit() { quits += 1 }
}
