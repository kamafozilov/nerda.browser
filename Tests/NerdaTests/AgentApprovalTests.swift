import Darwin
import Foundation
import Testing
@testable import Nerda

/// Another program than Nerda's own command line drives Nerda only once the
/// owner allows it (spec #119, ticket #132). The test process is that other
/// program: it is signed, but not to the made-up requirement these servers
/// let in without asking.
@MainActor
struct AgentApprovalTests {
    private static let stranger = #"identifier "dev.nerda.nobody" and anchor apple generic"#

    /// The first time an unknown program asks for more than status, the
    /// owner is asked, once, however often it asks again; until they answer
    /// it learns only Nerda's status, and no page is opened for it.
    @Test func anUnknownProgramIsAskedAboutOnceAndGetsStatusUntilAllowed() async throws {
        let owner = TestOwner()
        let harness = try AgentHarness(callers: AgentCallers(requiring: Self.stranger), ask: owner.ask)
        defer { harness.close() }
        let url = try await harness.pages.serve("/page", "<title>Page</title><p>Here</p>")
        let agent = try await harness.agent()

        let first = try await agent.call("open", ["url": AgentJSON(url)])
        #expect(first.isError)
        #expect(first.text.contains("asking the user"), "\(first.text)")
        try await waitFor { owner.asked.count == 1 }
        let program = try #require(owner.asked.first)
        #expect(!program.name.isEmpty)
        #expect(FileManager.default.fileExists(atPath: program.path), "\(program.path)")
        #expect(first.text.contains(program.name))

        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError)
        #expect(try await agent.call("tabs").isError)
        let status = try await agent.call("status")
        #expect(!status.isError, "\(status.text)")
        #expect(owner.asked.count == 1)
        #expect(harness.pages.requests(for: "/page").isEmpty)

        owner.answer(.once)
        try await waitFor { harness.server.approvals.decision(for: program) == true }
        let opened = try await agent.call("open", ["url": AgentJSON(url)])
        #expect(!opened.isError, "\(opened.text)")
        #expect(opened.text.contains("Here"))
        #expect(owner.asked.count == 1)
        // Once is until Nerda quits: nothing is kept for the next time.
        #expect(harness.server.approvals.remembered.isEmpty)
        #expect(AgentApprovals(defaults: harness.defaults).decision(for: program) == nil)
    }

    /// The caller check on its own, on the two ends of a socket pair: the
    /// peer is this process, which meets its own designated requirement as
    /// Nerda's command line meets the app's, and no made-up one; failing it,
    /// it is told apart by that same requirement of its own.
    @Test func theCallerCheckLetsInNerdasRequirementAndRefusesOthers() throws {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        defer { Darwin.close(ends[0]) }
        let connection = AgentSocket.Connection(fd: ends[1])
        defer { connection.close() }
        #expect(connection.uid == getuid())

        let own = AgentCallers.ownRequirement()
        let ownText = try #require(own.requirement.flatMap { requirement in
            var text: CFString?
            return SecRequirementCopyString(requirement, [], &text) == errSecSuccess ? text as String? : nil
        }, "The test process has no designated requirement to check against")
        #expect(AgentCallers(requirement: own).access(of: connection) == .full)
        #expect(AgentCallers.anyone.access(of: connection) == .full)

        let refused = try AgentCallers(requiring: Self.stranger).access(of: connection)
        guard case .unknown(let program) = refused else {
            Issue.record("Not refused as an unknown program: \(String(describing: refused))")
            return
        }
        #expect(program.id == ownText)
        #expect(FileManager.default.fileExists(atPath: program.path))
    }

    /// Always is kept for the next time Nerda opens, and listed to be
    /// removed in Settings; removed, the program is asked about again.
    @Test func alwaysIsRememberedAndCanBeRemoved() async throws {
        let owner = TestOwner()
        let harness = try AgentHarness(callers: AgentCallers(requiring: Self.stranger), ask: owner.ask)
        defer { harness.close() }
        let url = try await harness.pages.serve("/page", "<title>Page</title><p>Here</p>")
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError)
        try await waitFor { owner.asked.count == 1 }
        let program = try #require(owner.asked.first)

        owner.answer(.always)
        try await waitFor { harness.server.approvals.decision(for: program) == true }
        #expect(!(try await agent.call("open", ["url": AgentJSON(url)]).isError))
        // As Nerda next opens: Settings lists it, and it is let in.
        let later = AgentApprovals(defaults: harness.defaults, ask: { _ in nil })
        #expect(later.remembered.map(\.program) == [program])
        #expect(later.remembered.first?.allowed == true)
        #expect(later.decision(for: program) == true)

        // Removed in Settings: asked about again, status only meanwhile.
        harness.server.approvals.forget(program)
        #expect(harness.server.approvals.remembered.isEmpty)
        #expect(AgentApprovals(defaults: harness.defaults).remembered.isEmpty)
        let again = try await agent.call("tabs")
        #expect(again.isError)
        #expect(again.text.contains("asking the user"), "\(again.text)")
        try await waitFor { owner.asked.count == 2 }
    }

    /// Don't allow is kept too: the program gets status only and the owner
    /// isn't asked again, until they remove it in Settings.
    @Test func dontAllowIsRememberedWithoutAskingAgain() async throws {
        let owner = TestOwner()
        let harness = try AgentHarness(callers: AgentCallers(requiring: Self.stranger), ask: owner.ask)
        defer { harness.close() }
        let url = try await harness.pages.serve("/page", "<title>Page</title>")
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError)
        try await waitFor { owner.asked.count == 1 }
        let program = try #require(owner.asked.first)

        owner.answer(.never)
        try await waitFor { harness.server.approvals.decision(for: program) == false }
        let refused = try await agent.call("open", ["url": AgentJSON(url)])
        #expect(refused.isError)
        #expect(refused.text.contains("didn't allow"), "\(refused.text)")
        #expect(!(try await agent.call("status").isError))
        try await Task.sleep(for: .milliseconds(100))
        #expect(owner.asked.count == 1)
        #expect(harness.pages.requests(for: "/page").isEmpty)
        #expect(AgentApprovals(defaults: harness.defaults).remembered.first?.allowed == false)
    }
}

/// The owner, as the approval sheet asks them: what they were asked about,
/// and their answer when the test gives it.
@MainActor
final class TestOwner {
    private(set) var asked: [AgentProgram] = []
    private var waiting: [CheckedContinuation<AgentApprovals.Choice?, Never>] = []

    var ask: AgentApprovals.Ask {
        { program in
            self.asked.append(program)
            return await withCheckedContinuation { self.waiting.append($0) }
        }
    }

    /// Answers the question shown, as the owner pressing a button.
    func answer(_ choice: AgentApprovals.Choice?) {
        guard !waiting.isEmpty else { Issue.record("Nothing was asked"); return }
        waiting.removeFirst().resume(returning: choice)
    }
}
