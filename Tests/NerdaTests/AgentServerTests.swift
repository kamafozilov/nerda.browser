import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents reach Nerda over MCP (spec #119, ticket #130): a page opened in an
/// Agent tab and read back, sessions kept apart, and who gets in.
@MainActor
struct AgentServerTests {
    /// What an agent opens comes back in the same answer: which tab it is
    /// in, the page's title and address, and the start of its text.
    @Test func openAnswersTheTabTitleAddressAndText() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/account", "<title>Account</title><h1>Hello</h1><p>Signed in as Kamron</p>")
        let agent = try await harness.agent()

        let answer = try await agent.call("open", ["url": AgentJSON(url)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("tab: t1"))
        #expect(answer.text.contains("title: Account"))
        #expect(answer.text.contains("address: \(url.absoluteString)"))
        #expect(answer.text.contains("Signed in as Kamron"))
        // An Agent tab: in the agents' browser, out of the owner's.
        let tab = try #require(harness.agents?.tabs.first)
        #expect(tab.url == url)
        #expect(!Windows.browsers.contains { $0 === harness.agents?.browser })
    }

    /// An agent connects again and again (each shim is started anew, and
    /// may be killed between calls): with the same harness session id it is
    /// the same Agent session, with the same tabs.
    @Test func connectionsWithOneSessionIDShareOneSession() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/one", "<title>One</title><p>First page</p>")
        let first = try await harness.agent(session: "abc")
        #expect(try await first.call("open", ["url": AgentJSON(url)]).text.contains("tab: t1"))

        let again = try await harness.agent(session: "abc")
        let tabs = try await again.call("tabs")
        #expect(tabs.text.contains("t1"))
        #expect(tabs.text.contains("One"))
        #expect(tabs.text.contains(url.absoluteString))
        #expect(harness.server.sessions.all.count == 1)
        #expect(harness.server.sessions.all.first?.title == "Claude")

        // Another session id is another session, with none of these tabs.
        let other = try await harness.agent(session: "xyz")
        #expect(try await other.call("tabs").text.contains("No Agent tabs"))
        #expect(harness.server.sessions.all.count == 2)
    }

    /// Several agents at work at once never touch each other's tabs, and
    /// none sees the owner's incognito tabs.
    @Test func aSessionCantUseAnotherSessionsTabsNorIncognito() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let mine = try await harness.pages.serve("/mine", "<title>Mine</title><p>Mine</p>")
        let elsewhere = try await harness.pages.serve("/elsewhere", "<title>Elsewhere</title>")
        let claude = try await harness.agent(client: "claude-code", session: "one")
        let codex = try await harness.agent(client: "codex-mcp-client", session: "two")
        _ = try await claude.call("open", ["url": AgentJSON(mine)])

        let navigate = try await codex.call("navigate", ["tab": "t1", "url": AgentJSON(elsewhere)])
        #expect(navigate.isError)
        #expect(navigate.text.contains("another agent"))
        let close = try await codex.call("close", ["tab": "t1"])
        #expect(close.isError)
        #expect(try await codex.call("tabs").text.contains("No Agent tabs"))
        // Untouched: still open, still where it was.
        #expect(harness.agents?.tabs.count == 1)
        #expect(harness.agents?.tabs.first?.url == mine)
        #expect(harness.pages.requests(for: "/elsewhere").isEmpty)

        // The owner's incognito window: its tab is no tab to any agent.
        let incognito = Browser(dataStore: .nonPersistent())
        let secret = incognito.open(try await harness.pages.serve("/secret", "<title>Secret</title>"))
        try await waitFor { !harness.pages.requests(for: "/secret").isEmpty }
        let list = try await claude.call("tabs")
        #expect(!list.text.contains("Secret"))
        for name in [secret.id.uuidString, "t2", "t0"] {
            #expect(try await claude.call("close", ["tab": .string(name)]).isError)
        }
        #expect(incognito.tabs.count == 1)
    }

    /// An agent takes its tab elsewhere, and closes it; a closed tab's name
    /// says it was closed.
    @Test func navigateAndCloseWorkOnTheSessionsOwnTab() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let first = try await harness.pages.serve("/first", "<title>First</title><p>Start here</p>")
        let second = try await harness.pages.serve("/second", "<title>Second</title><p>Then here</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(first)])

        let moved = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(second)])
        #expect(!moved.isError, "\(moved.text)")
        #expect(moved.text.contains("tab: t1"))
        #expect(moved.text.contains("title: Second"))
        #expect(moved.text.contains("Then here"))

        let closed = try await agent.call("close", ["tab": "t1"])
        #expect(!closed.isError)
        #expect(harness.agents?.tabs.isEmpty == true)
        let again = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(first)])
        #expect(again.isError)
        #expect(again.text.contains("t1 was closed"))
    }

    /// A page that can't be opened fails at once, saying why, rather than
    /// waiting out the deadline.
    @Test func anAddressThatCantBeOpenedFailsAtOnce() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()
        let started = ContinuousClock.now
        let answer = try await agent.call("open", ["url": "http://nothing-here.invalid/"])
        #expect(answer.isError)
        #expect(answer.text.contains("couldn't be opened"))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// A shim from another version of Nerda than the one running (Nerda
    /// updated, not reopened) is told plainly to reopen Nerda, whichever
    /// side is newer.
    @Test func aWireVersionMismatchAnswersReopenNerda() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/page", "<title>Page</title>")
        for wire in [AgentWire.version + 1, AgentWire.version - 1] {
            let agent = try await harness.agent(wire: wire)
            let answer = try await agent.call("open", ["url": AgentJSON(url)])
            #expect(answer.isError)
            #expect(answer.text.contains("reopen Nerda"))
        }
        #expect(harness.pages.requests(for: "/page").isEmpty)
        #expect(harness.agents == nil)
    }

    /// A program whose signature doesn't meet the requirement (in a release
    /// build, Nerda's own) learns only whether Nerda is there; one that does
    /// gets everything. The test process connects, so its own signature is
    /// what is checked.
    @Test func aCallerFailingTheSignatureCheckGetsStatusOnly() async throws {
        let refused = try AgentHarness(callers: AgentCallers(requiring: #"identifier "dev.nerda.nobody" and anchor apple generic"#))
        defer { refused.close() }
        let url = try await refused.pages.serve("/page", "<title>Page</title>")
        let stranger = try await refused.agent()
        let open = try await stranger.call("open", ["url": AgentJSON(url)])
        #expect(open.isError)
        #expect(open.text.contains("only tells it its status"))
        #expect(try await stranger.call("tabs").isError)
        let status = try await stranger.call("status")
        #expect(!status.isError, "\(status.text)")
        #expect(status.text.contains("is running"))
        #expect(refused.pages.requests(for: "/page").isEmpty)

        // The requirement the test process's own signature was made to meet,
        // as Nerda's own command line meets the app's.
        let own = AgentCallers.ownRequirement()
        try #require(own.requirement != nil, "The test process has no designated requirement to check against")
        let allowed = try AgentHarness(callers: AgentCallers(requirement: own))
        defer { allowed.close() }
        let mine = try await allowed.agent()
        let page = try await allowed.pages.serve("/page", "<title>Page</title><p>Here</p>")
        let opened = try await mine.call("open", ["url": AgentJSON(page)])
        #expect(!opened.isError, "\(opened.text)")
    }

    /// Settings › Security & Privacy › Agents can use Nerda, turned off,
    /// leaves nothing for agents to reach; turned on, they reach it again.
    @Test func theSettingsSwitchTurnsTheServerOff() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()
        #expect(harness.server.isOn)
        #expect(!(try await agent.call("status").isError))

        harness.defaults.set(false, forKey: AgentServer.isOnKey)
        #expect(!harness.server.isListening)
        #expect(!FileManager.default.fileExists(atPath: harness.socket.path))
        let off = try await agent.call("status")
        #expect(off.isError)
        #expect(off.text.contains("turned off"))

        harness.defaults.set(true, forKey: AgentServer.isOnKey)
        #expect(harness.server.isListening)
        #expect(!(try await agent.call("status").isError))
    }

    /// The tools an MCP client is shown are the verbs, each with its
    /// arguments, and marked as reading only or destroying.
    @Test func theToolListIsTheVerbs() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let tools = try await harness.agent().tools()
        let names = tools.compactMap { $0["name"]?.string }
        #expect(Set(["open", "navigate", "tabs", "close", "status"]).isSubset(of: Set(names)))
        let open = try #require(tools.first { $0["name"] == "open" })
        #expect(open["inputSchema"]?["required"] == ["url"])
        #expect(tools.first { $0["name"] == "tabs" }?["annotations"]?["readOnlyHint"] == true)
        #expect(tools.first { $0["name"] == "close" }?["annotations"]?["destructiveHint"] == true)
    }
}
