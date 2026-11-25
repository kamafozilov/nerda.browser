import Foundation
import Testing
import WebKit
@testable import Nerda

/// A finished agent's tabs don't pile up (spec #119, ticket #146): they
/// close 15 minutes after their session last used them, counting only time
/// the Mac is awake, unless they hold something typed. The harness's clock
/// is moved by hand, so no test waits the 15 minutes.
@MainActor
struct AgentCleanupTests {
    /// Tabs its session stopped using close once 15 awake minutes have
    /// passed, not before; and the agent asking for one later is told it was
    /// closed after its session ended, not just that there is no such tab.
    @Test func idleAgentTabsCloseAfterFifteenMinutes() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/report", "<title>Report</title><p>Numbers</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        harness.clock.advance(by: .seconds(14 * 60 + 59))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.count == 2)

        harness.clock.advance(by: .seconds(1))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.isEmpty == true)

        let later = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(url)])
        #expect(later.isError)
        #expect(later.text.contains("t1 was closed after its session ended"), "\(later.text)")
    }

    /// Any request from the session is a use, and starts the 15 minutes
    /// again for all its tabs.
    @Test func aSessionAtWorkKeepsItsTabs() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/report", "<title>Report</title><p>Numbers</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        harness.clock.advance(by: .seconds(10 * 60))
        _ = try await agent.call("tabs")
        harness.clock.advance(by: .seconds(10 * 60))
        harness.server.cleanUp()

        #expect(harness.agents?.tabs.count == 1)
        #expect(try await agent.call("tabs").text.contains("t1"))
    }

    /// A tab holding something typed stays until it is dealt with, while
    /// the session's other tabs close.
    @Test func aTabWithUnsavedInputIsKept() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let form = try await harness.pages.serve("/form", "<title>Form</title><textarea id=note></textarea>")
        let plain = try await harness.pages.serve("/plain", "<title>Plain</title><p>Nothing to type</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(form)])
        _ = try await agent.call("open", ["url": AgentJSON(plain)])
        let drafted = try #require(harness.agents?.tabs.first { $0.url == form })
        // Typed text (execCommand's input is trusted, as keys are).
        _ = try await drafted.page?.evaluateJavaScript(
            "document.getElementById('note').focus(); document.execCommand('insertText', false, 'Dear team')"
        )
        try await waitFor { drafted.hasUnsavedWork }

        harness.clock.advance(by: .seconds(16 * 60))
        harness.server.cleanUp()

        #expect(harness.agents?.tabs.map(\.url) == [form])
        let tabs = try await agent.call("tabs")
        #expect(tabs.text.contains("t1"))
        #expect(!tabs.text.contains("t2"))
    }

    /// The MCP client closing the shim's input (the agent finished) detaches
    /// its session; its tabs stay for the 15 minutes all the same, and a new
    /// request attaches it again.
    @Test func anAgentGoingAwayDetachesItsSession() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/report", "<title>Report</title><p>Numbers</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let session = try #require(harness.server.sessions.all.first)
        #expect(!session.isDetached)

        harness.clock.advance(by: .seconds(10 * 60))
        await agent.mcp.detach()
        #expect(session.isDetached)
        // Going away is no use of the tabs: the 15 minutes still count from the open.
        harness.clock.advance(by: .seconds(5 * 60))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.isEmpty == true)

        _ = try await agent.call("tabs")
        #expect(!session.isDetached)
    }
}
