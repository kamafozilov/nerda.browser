import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Nerda

/// Take over (spec #119, ticket #145): the owner's click or key in an Agent
/// tab they watch, or ⌘., takes it; the agent's calls on it are then told
/// the owner took it, until ⌘↩ hands it back. Or the owner keeps it as a
/// tab of their own, and it leaves the agent's session.
@MainActor
struct AgentTakeOverTests {
    /// A click of the owner's in the Agent tab they watch takes it over:
    /// the agent's next call on it is told so. The agent's own click in it,
    /// as the owner watches, takes nothing.
    @Test func theOwnersClickInAWatchedAgentTabTakesItOver() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/shop", "<title>Shop</title><button>Add to basket</button>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let (owner, window, page) = try await watch(harness)
        defer { window.close() }

        let ref = try #require(AgentClickTests.ref(of: "button \"Add to basket\"", in: try await agent.call("snapshot", ["tab": "t1"]).text))
        let clicked = try await agent.call("click", ["tab": "t1", "ref": .string(ref)])
        #expect(!clicked.isError, "\(clicked.text)")
        #expect(!(try await agent.call("text", ["tab": "t1"]).isError))

        ownerClick(page)
        let refused = try await agent.call("text", ["tab": "t1"])
        #expect(refused.isError)
        #expect(refused.text.contains("The user took over tab t1"), "\(refused.text)")
        #expect(try await agent.call("tabs").text.contains("t1  Shop"))
        #expect(try await agent.call("tabs").text.contains("the user took it over"))
        // Still watched, in the owner's window, and still the agent's.
        #expect(owner.watchedTab === harness.agents?.tabs.first)
        #expect(page.window === window)
    }

    /// A key of the owner's in the page takes it over too, and so does ⌘.
    /// without touching the page; ⌘↩ hands it back, and the agent's calls
    /// work again. ⌘↩ in a tab not taken is the page's.
    @Test func commandReturnHandsTheTabBack() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/form", "<title>Form</title><input id=name>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let (_, window, page) = try await watch(harness)
        defer { window.close() }

        page.keyDown(with: try key("a", code: 0, in: window))
        #expect(try await agent.call("text", ["tab": "t1"]).text.contains("took over tab t1"))

        #expect(AgentServer.ownerKey(try key("\r", code: 36, modifiers: .command, in: window)))
        let again = try await agent.call("text", ["tab": "t1"])
        #expect(!again.isError, "\(again.text)")
        #expect(!AgentServer.ownerKey(try key("\r", code: 36, modifiers: .command, in: window)))

        #expect(AgentServer.ownerKey(try key(".", code: 47, modifiers: .command, in: window)))
        #expect(try await agent.call("text", ["tab": "t1"]).text.contains("took over tab t1"))
        #expect(AgentServer.ownerKey(try key("\r", code: 36, modifiers: .command, in: window)))
        #expect(!(try await agent.call("text", ["tab": "t1"]).isError))
    }

    /// A tab the owner keeps moves to their tab list, on screen, page and
    /// all; it is no longer the agent's: not among its tabs, and asking for
    /// it says the user kept it. Cleanup leaves it alone.
    @Test func aKeptTabMovesToTheOwnersTabsAndLeavesTheSession() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/cart", "<title>Cart</title><p>Two items</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let (owner, window, page) = try await watch(harness)
        defer { window.close() }
        let agents = try #require(harness.agents)
        let agentTab = try #require(agents.tabs.first)
        let tab = try #require(owner.watched)

        ownerClick(page)
        harness.server.keep(tab, in: owner)

        #expect(owner.selected === agentTab)
        #expect(owner.watched == nil)
        #expect(!agents.tabs.contains { $0 === agentTab })
        #expect(agentTab.page === page)
        try await waitFor { page.window === window && !page.isHiddenOrHasHiddenAncestor }
        #expect(try await agent.call("tabs").text.contains("No Agent tabs open"))
        let asked = try await agent.call("text", ["tab": "t1"])
        #expect(asked.isError)
        #expect(asked.text.contains("kept tab t1 as their own"), "\(asked.text)")

        harness.clock.advance(by: .seconds(60 * 60))
        harness.server.cleanUp()
        #expect(owner.tabs.contains { $0 === agentTab })
    }

    /// A tab the owner took over stays open past cleanup, however long its
    /// agent has been quiet, until handed back.
    @Test func cleanupLeavesATakenTab() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/report", "<title>Report</title>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let (_, window, page) = try await watch(harness)
        defer { window.close() }

        ownerClick(page)
        harness.clock.advance(by: .seconds(60 * 60))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.count == 1)

        #expect(AgentServer.ownerKey(try key("\r", code: 36, modifiers: .command, in: window)))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.isEmpty == true)
    }

    /// Doing the step an agent asked for (a Handoff) is no Take over: the
    /// agent carries on in the tab once the owner is done.
    @Test func doingAHandoffStepTakesNothing() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/code", "<title>Code</title><input id=code>")
        let agent = try await harness.agent(waits: AgentRowTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await agent.call("handoff", ["tab": "t1", "step": "code", "reason": "Enter the code"])
        let (_, window, page) = try await watch(harness)
        defer { window.close() }

        ownerClick(page)
        page.keyDown(with: try key("4", code: 21, in: window))
        let request = try #require(harness.server.owner.waiting.first)
        harness.server.owner.done(request)

        let after = try await agent.call("text", ["tab": "t1"])
        #expect(!after.isError, "\(after.text)")
    }

    // MARK: - Helpers

    /// A key of the owner's keyboard, as the window `window` gets it.
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    /// The session's first Agent tab watched in an owner's window of the
    /// Agent browser's store, and its page there.
    private func watch(_ harness: AgentHarness) async throws -> (Browser, NSWindow, WKWebView) {
        let agents = try #require(harness.agents)
        let owner = Browser(dataStore: agents.browser.dataStore)
        owner.open(URL(string: "about:blank")!)
        let window = ownerWindow(of: owner)
        let session = try #require(harness.server.sessions.all.first)
        let tab = try #require(harness.server.openTabs(of: session).first)
        let page = try #require(tab.tab.page)
        harness.server.watch(tab, in: owner)
        try await waitFor { page.window === window && !page.isHiddenOrHasHiddenAncestor }
        return (owner, window, page)
    }

    /// A click of the owner's mouse in the middle of the page, as the
    /// window gives it to the page: not one an agent sent.
    private func ownerClick(_ page: WKWebView) {
        let point = page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: page.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { page.mouseDown(with: event) } else { page.mouseUp(with: event) }
        }
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
