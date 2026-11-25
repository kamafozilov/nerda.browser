import Foundation
import Testing
@testable import Nerda

/// The `nerda-browser` command (spec #119, ticket #131): the same verbs as
/// the MCP tools, for scripts and shell-only agents, over the same socket,
/// with exit codes a script can tell apart.
@MainActor
struct AgentCommandLineTests {
    /// A verb's arguments go in the order the tool list gives them: the
    /// page opens, its answer is printed, and the command exits 0.
    @Test func aVerbRunsWithItsArgumentsInOrder() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let first = try await harness.pages.serve("/first", "<title>First</title><p>Start here</p>")
        let second = try await harness.pages.serve("/second", "<title>Second</title><p>Then here</p>")
        let shell = ["NERDA_BROWSER_SESSION": "script-1"]

        let opened = await AgentCommandLine.run(["open", first.absoluteString], environment: shell, socket: harness.socket)
        #expect(opened.status == 0, "\(opened.errors)")
        #expect(opened.output.contains("tab: t1"))
        #expect(opened.output.contains("Start here"))

        let moved = await AgentCommandLine.run(["navigate", "t1", second.absoluteString], environment: shell, socket: harness.socket)
        #expect(moved.status == 0, "\(moved.errors)")
        #expect(moved.output.contains("Then here"))
        // Named, in any place, as --name value.
        let closed = await AgentCommandLine.run(["close", "--tab", "t1"], environment: shell, socket: harness.socket)
        #expect(closed.status == 0, "\(closed.errors)")
        #expect(harness.agents?.tabs.isEmpty == true)
    }

    /// Run from a Claude Code shell, the command is in the same Agent
    /// session as Claude Code's MCP calls: it sees the same tabs.
    @Test func inAClaudeCodeShellItSharesTheMCPSession() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/one", "<title>One</title><p>First page</p>")
        let agent = try await harness.agent(client: "claude-code", session: "claude-42")
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let listed = await AgentCommandLine.run(["tabs"], environment: ["CLAUDE_CODE_SESSION_ID": "claude-42"], socket: harness.socket)
        #expect(listed.status == 0, "\(listed.errors)")
        #expect(listed.output.contains("t1"))
        #expect(listed.output.contains("One"))
        #expect(harness.server.sessions.all.count == 1)
    }

    /// A failure is said on standard error, and the exit code says which
    /// kind: 1 failed, 2 Nerda unreachable.
    @Test func failuresExitWithTheirCode() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }

        let noTab = await AgentCommandLine.run(["close", "t9"], environment: [:], socket: harness.socket)
        #expect(noTab.status == 1)
        #expect(noTab.output.isEmpty)
        #expect(noTab.errors.contains("no tab t9"))

        let unknown = await AgentCommandLine.run(["fly"], environment: [:], socket: harness.socket)
        #expect(unknown.status == 1)
        #expect(unknown.errors.contains("fly"))

        let missing = await AgentCommandLine.run(["open"], environment: [:], socket: harness.socket)
        #expect(missing.status == 1)
        #expect(missing.errors.contains("url"))

        let nowhere = harness.folder.appending(path: "none.sock")
        let unreachable = await AgentCommandLine.run(["tabs"], environment: [:], socket: nowhere)
        #expect(unreachable.status == 2)
        #expect(unreachable.errors.contains("Nerda isn't running"))
    }

    /// Kinds of failure no verb gives yet still have their own codes: 3
    /// when the owner is needed, 124 when time ran out.
    @Test func eachKindOfAnswerHasItsExitCode() {
        #expect(AgentCommandLine.status(of: .done("ok")) == 0)
        #expect(AgentCommandLine.status(of: .failed(AgentError(.failed, ""))) == 1)
        #expect(AgentCommandLine.status(of: .failed(AgentError(.unreachable, ""))) == 2)
        #expect(AgentCommandLine.status(of: .failed(AgentError(.needsUser, ""))) == 3)
        #expect(AgentCommandLine.status(of: .failed(AgentError(.timedOut, ""))) == 124)
        #expect(AgentCommandLine.interrupted == 130)
    }

    /// With no verb, or asked for help, it lists every verb and the exit
    /// codes.
    @Test func helpListsTheVerbs() async {
        let help = await AgentCommandLine.run(["--help"], environment: [:], socket: URL(fileURLWithPath: "/nowhere"))
        #expect(help.status == 0)
        for verb in AgentVerb.all { #expect(help.output.contains(verb.name)) }
        #expect(help.output.contains("124"))
        let bare = await AgentCommandLine.run([], environment: [:], socket: URL(fileURLWithPath: "/nowhere"))
        #expect(bare.status == 1)
        #expect(bare.errors.contains("open"))
    }
}
