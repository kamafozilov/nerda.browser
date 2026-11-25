import AppKit
import SwiftUI
import Testing
@testable import Nerda

/// The Agent row (spec #119, ticket #144): one row at the sidebar's foot
/// saying which agents are at work and when one needs the owner, and its
/// panel, from which the owner watches an Agent tab in their own window,
/// stops an agent or closes its tabs.
@MainActor
struct AgentRowTests {
    /// Short waits, so a test doesn't sit out the real 15 s.
    static let quick = AgentMCP.Waits(withProgress: .seconds(600), withoutProgress: .seconds(1),
                                      poll: .seconds(1), progressEvery: .milliseconds(200))

    /// No row before any agent; "Claude" while one works, "2 agents" with
    /// a second; idle once they have gone quiet, with tabs still open; and
    /// gone once no tab is left.
    @Test func theRowSaysWhichAgentsAreAtWork() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        #expect(harness.server.activity().state == nil)

        let url = try await harness.pages.serve("/a", "<title>A</title>")
        let claude = try await harness.agent()
        _ = try await claude.call("open", ["url": AgentJSON(url)])
        var row = harness.server.activity()
        #expect(row.state == .atWork)
        #expect(row.title == "Claude")
        #expect(row.atWork.map(\.title) == ["Claude"])

        let codex = try await harness.agent(client: "codex-mcp-client", session: "thread-2")
        _ = try await codex.call("open", ["url": AgentJSON(url)])
        row = harness.server.activity()
        #expect(row.state == .atWork)
        #expect(row.title == "2 agents")
        // The one heard from last first.
        #expect(row.atWork.map(\.title) == ["Codex", "Claude"])

        harness.clock.advance(by: .seconds(5 * 60))
        row = harness.server.activity()
        #expect(row.state == .idle)
        #expect(row.atWork.isEmpty)
        #expect(row.earlier.map(\.title) == ["Codex", "Claude"])

        for session in harness.server.sessions.all { harness.server.closeTabs(of: session) }
        #expect(harness.server.activity().state == nil)
        #expect(harness.server.activity().earlier.count == 2)
    }

    /// A session waiting on the owner is listed under Needs you, and the
    /// row says so; the others stay at work.
    @Test func theRowSaysWhenAnAgentNeedsTheOwner() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/login", "<title>Log in</title>")
        let claude = try await harness.agent(waits: Self.quick)
        _ = try await claude.call("open", ["url": AgentJSON(url)])
        let codex = try await harness.agent(client: "codex-mcp-client", session: "thread-2")
        _ = try await codex.call("open", ["url": AgentJSON(url)])

        _ = try await claude.call("handoff", ["tab": "t1", "step": "sign_in", "reason": "Sign in to the shop"])
        var row = harness.server.activity()
        #expect(row.state == .needsYou)
        #expect(row.title == "Claude needs you")
        #expect(row.needsYou.map(\.title) == ["Claude"])
        #expect(row.atWork.map(\.title) == ["Codex"])
        #expect(row.earlier.isEmpty)

        // Still needing the owner after the agent has gone quiet.
        harness.clock.advance(by: .seconds(5 * 60))
        row = harness.server.activity()
        #expect(row.state == .needsYou)
        #expect(row.needsYou.map(\.title) == ["Claude"])
        #expect(row.earlier.map(\.title) == ["Codex"])

        harness.server.owner.done(try #require(harness.server.owner.waiting.first))
        #expect(harness.server.activity().state == .idle)
    }

    /// Opened from the panel, an Agent tab shows in the owner's window, in
    /// place of their own tab; the agent goes on using it; and going back
    /// to a tab of the owner's puts it back among the Agent tabs.
    @Test func anAgentTabOpenedFromThePanelShowsInTheOwnersWindow() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let first = try await harness.pages.serve("/one", "<title>One</title><p>First</p>")
        let second = try await harness.pages.serve("/two", "<title>Two</title><p>Second</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(first)])
        let agents = try #require(harness.agents)
        let agentTab = try #require(agents.tabs.first)
        let agentPage = try #require(agentTab.page)
        #expect(agentPage.window === agents.window)

        let owner = Browser(dataStore: .nonPersistent())
        let own = owner.open(URL(string: "about:blank")!)
        let window = ownerWindow(of: owner)
        defer { window.close() }
        let session = try #require(harness.server.sessions.all.first)
        let tab = try #require(harness.server.sessions.tabs(of: session).first)

        harness.server.watch(tab, in: owner)
        try await waitFor { agentPage.window === window && !agentPage.isHiddenOrHasHiddenAncestor }
        #expect(owner.watchedTab === agentTab)
        #expect(owner.selected === own)
        // Not one of the owner's tabs, nor taken from the agent.
        #expect(!owner.tabs.contains { $0 === agentTab })
        #expect(agents.tabs.contains { $0 === agentTab })
        // The agent carries on in it, as the owner watches.
        let moved = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(second)])
        #expect(!moved.isError, "\(moved.text)")
        try await waitFor { agentTab.title == "Two" }
        #expect(agentPage.window === window)

        owner.select(own.id)
        #expect(owner.watchedTab == nil)
        try await waitFor { agentPage.window === agents.window }
    }

    /// A Handoff's notification clicked shows its tab in the owner's window.
    @Test func aClickedHandoffShowsItsTabInTheOwnersWindow() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/code", "<title>Code</title>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await agent.call("handoff", ["tab": "t1", "step": "code", "reason": "Enter the code"])
        let owner = Browser(dataStore: .nonPersistent())
        owner.open(URL(string: "about:blank")!)
        harness.server.ownerWindow = { owner }

        let request = try #require(harness.server.owner.waiting.first)
        harness.server.show(request)
        #expect(owner.watchedTab === harness.agents?.tabs.first)
    }

    /// Stop ends the session: a call waiting on the owner is answered that
    /// the owner stopped it, its Handoff goes, and the agent's next call is
    /// told too; after that, it starts afresh. Its tabs stay for the owner.
    @Test func stopEndsTheSession() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/form", "<title>Form</title>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let waiting = Task {
            try await agent.call("handoff", ["tab": "t1", "reason": "Accept the terms"], progressToken: "p")
        }
        try await waitFor { !harness.server.owner.waiting.isEmpty }
        let session = try #require(harness.server.sessions.all.first)

        harness.server.stop(session)
        let stopped = try await waiting.value
        #expect(stopped.isError)
        #expect(stopped.text.contains("stopped"))
        #expect(harness.server.owner.waiting.isEmpty)
        #expect(harness.server.activity().needsYou.isEmpty)
        #expect(harness.server.activity().earlier.first === session)
        #expect(harness.agents?.tabs.count == 1)

        // Told once, the agent may start again, in a session of its own.
        let again = try await agent.call("tabs")
        #expect(!again.isError, "\(again.text)")
        #expect(!again.text.contains("t1"))
        #expect(harness.server.sessions.all.count == 2)
        #expect(harness.server.activity().atWork.count == 1)
    }

    /// Stop with nothing in flight: the next call hears it.
    @Test func anIdleAgentHearsItWasStoppedOnItsNextCall() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/p", "<title>P</title>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        harness.server.stop(try #require(harness.server.sessions.all.first))

        let told = try await agent.call("tabs")
        #expect(told.isError)
        #expect(told.text.contains("stopped"))
        let next = try await agent.call("tabs")
        #expect(!next.isError, "\(next.text)")
    }

    /// Close closes the session's tabs; the agent is told the owner closed them.
    @Test func closeClosesTheSessionsTabs() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/p", "<title>P</title>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let session = try #require(harness.server.sessions.all.first)
        #expect(harness.agents?.tabs.count == 2)

        harness.server.closeTabs(of: session)
        #expect(harness.agents?.tabs.isEmpty == true)
        let answer = try await agent.call("navigate", ["tab": "t2", "url": AgentJSON(url)])
        #expect(answer.isError)
        #expect(answer.text.contains("closed by the user"))
    }

    /// The owner's window for `browser`, never in front of the one in use:
    /// a plain window, not a `BrowserWindow`, so no link comes to it.
    private func ownerWindow(of browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
        window.orderBack(nil)
        return window
    }
}
