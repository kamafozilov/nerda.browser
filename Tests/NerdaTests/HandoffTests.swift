import AppKit
import Foundation
import Testing
@testable import Nerda

/// Agents asking the owner (spec #119, ticket #143): a Handoff for a step
/// only a person can do, and a question with a few choices. The agent waits
/// with progress, or is told the owner is needed; the owner is told by a
/// notification and a line on the page, and Nerda never comes forward.
@MainActor
struct HandoffTests {
    /// Short waits, so a test doesn't sit out the real 15 s.
    static let quick = AgentMCP.Waits(withProgress: .seconds(600), withoutProgress: .seconds(1),
                                      poll: .seconds(1), progressEvery: .milliseconds(200))

    /// A Handoff tells the owner (a notification, a line at the foot of the
    /// Agent tab's page) without bringing Nerda forward, and Done ends it:
    /// the agent's call, waiting all along, carries on.
    @Test func aHandoffTellsTheOwnerAndDoneEndsIt() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/captcha", "<title>Check</title><p>Are you a person?</p>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let active = NSApp.isActive
        let key = NSApp.keyWindow

        let call = Task {
            try await agent.call("handoff", ["tab": "t1", "step": "captcha", "reason": "Solve the captcha on Check"],
                                 progressToken: "p1")
        }
        try await waitFor { !harness.server.owner.waiting.isEmpty }
        let request = try #require(harness.server.owner.waiting.first)
        let notice = try #require(harness.notifier.posted.first)
        #expect(harness.notifier.posted.count == 1)
        #expect(notice.title.contains("Claude"))
        #expect(notice.body.contains("Solve the captcha on Check"))
        // The line at the foot of the tab's page, and the session needing the owner.
        let tab = try #require(harness.agents?.tabs.first)
        #expect(harness.server.owner.handoff(on: tab) === request)
        let session = try #require(harness.server.sessions.all.first)
        #expect(harness.server.owner.needs(session))
        #expect(NSApp.isActive == active)
        #expect(NSApp.keyWindow === key)

        harness.server.owner.done(request)
        let answer = try await call.value
        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("done"))
        #expect(answer.text.contains("tab: t1"))
        #expect(harness.server.owner.waiting.isEmpty)
        #expect(!harness.server.owner.needs(session))
        #expect(harness.notifier.withdrawn.contains(notice.id))
    }

    /// A client that sent a progress token (Claude Code) hears progress
    /// while it waits, for as long as the owner takes, past the shim's
    /// single requests to Nerda.
    @Test func aClientWithAProgressTokenHearsProgressWhileItWaits() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/code", "<title>Code</title><input autocomplete=one-time-code>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let call = Task {
            try await agent.call("handoff", ["tab": "t1", "step": "code", "reason": "Enter the code from your phone"],
                                 progressToken: 7)
        }
        // Past one request's wait (`poll`), still waiting, with progress.
        try await waitFor { agent.heard.progress.count >= 8 }
        #expect(agent.heard.progress.allSatisfy { $0["params"]?["progressToken"] == 7 })
        let values = agent.heard.progress.compactMap { $0["params"]?["progress"]?.number }
        #expect(values == values.sorted() && Set(values).count == values.count)
        let request = try #require(harness.server.owner.waiting.first)
        // Asked again by each of the shim's requests, the owner is told once.
        #expect(harness.notifier.posted.count == 1)

        harness.server.owner.done(request)
        let answer = try await call.value
        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("done"))
    }

    /// A client without one (Codex, whose calls end at 60 s) is answered
    /// needs_user after a short wait, saying what to tell the owner; the
    /// Handoff stays, and calling again picks up where it is.
    @Test func aClientWithoutAProgressTokenIsToldTheOwnerIsNeeded() async throws {
        #expect(AgentMCP.Waits().withoutProgress == .seconds(15))
        #expect(AgentMCP.Waits().withProgress == .seconds(600))
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/pass", "<title>Passkey</title>")
        let agent = try await harness.agent(client: "codex-mcp-client", waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let started = ContinuousClock.now
        let first = try await agent.call("handoff", ["tab": "t1", "step": "passkey", "reason": "Use your passkey"])
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!first.isError, "needs_user is no failure: \(first.text)")
        #expect(first.text.contains("needs_user"))
        #expect(first.text.contains("Use your passkey"))
        #expect(agent.heard.progress.isEmpty)
        let request = try #require(harness.server.owner.waiting.first)

        let again = try await agent.call("handoff", ["tab": "t1", "step": "passkey", "reason": "Use your passkey"])
        #expect(again.text.contains("needs_user"))
        #expect(harness.notifier.posted.count == 1)
        #expect(harness.server.owner.waiting.count == 1)

        // Done while nobody waits: the next call hears it at once.
        harness.server.owner.done(request)
        let done = try await agent.call("handoff", ["tab": "t1", "step": "passkey", "reason": "Use your passkey"])
        #expect(!done.isError, "\(done.text)")
        #expect(done.text.contains("done"))
        #expect(!done.text.contains("needs_user"))
        #expect(harness.notifier.posted.count == 1)
    }

    /// An optional Handoff can be skipped, and the agent hears it was; one
    /// that isn't optional has no Skip.
    @Test func skipEndsAnOptionalHandoff() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/news", "<title>News</title>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        _ = try await agent.call("handoff", ["tab": "t1", "reason": "Close the survey if you like", "optional": true])
        let request = try #require(harness.server.owner.waiting.first)
        #expect(request.canSkip)
        harness.server.owner.skip(request)
        let skipped = try await agent.call("handoff", ["tab": "t1", "reason": "Close the survey if you like", "optional": true])
        #expect(!skipped.isError)
        #expect(skipped.text.contains("skipped"))

        _ = try await agent.call("handoff", ["tab": "t1", "reason": "Accept the terms"])
        let required = try #require(harness.server.owner.waiting.first)
        #expect(!required.canSkip)
        harness.server.owner.skip(required)
        #expect(harness.server.owner.waiting.first === required)
    }

    /// A sign-in Handoff ends by itself once the tab is back on the site,
    /// signed in: not while the sign-in form is up, nor on the sign-in
    /// provider's site, but on the site's own page after them.
    @Test func aSignInHandoffEndsWhenTheTabIsBackOnTheSite() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let login = try await harness.pages.serve("/login", """
            <title>Sign in</title><form><input name=user autocomplete=username><input type=password name=pass></form>
            """)
        let provider = try await harness.pages.serve("/sso", """
            <title>Provider</title><form><input type=password name=pass></form>
            """, host: "localhost")
        let home = try await harness.pages.serve("/home", "<title>Home</title><p>Welcome back</p>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(login)])

        let waiting = try await agent.call("handoff", ["tab": "t1", "step": "sign_in", "reason": "Sign in to Shop"])
        #expect(waiting.text.contains("needs_user"))
        let tab = try #require(harness.agents?.tabs.first)
        // The owner goes to the provider's site, signs in there…
        tab.go(to: provider)
        try await waitFor { tab.url == provider && !tab.isLoading }
        try await Task.sleep(for: .seconds(1.5))
        #expect(harness.server.owner.waiting.count == 1)
        // …and the provider sends the tab back to the site.
        tab.go(to: home)
        try await waitFor(timeout: .seconds(10)) { harness.server.owner.waiting.isEmpty }

        let answer = try await agent.call("handoff", ["tab": "t1", "step": "sign_in", "reason": "Sign in to Shop"])
        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("signed in"))
        #expect(answer.text.contains("address: \(home.absoluteString)"))
    }

    /// The notification is shown again once, a few minutes on, while the
    /// owner hasn't come; never a third time.
    @Test func theNotificationIsRepeatedOnce() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.owner.repeatAfter = .milliseconds(300)
        #expect(OwnerRequests(notifier: RecordingNotifier()).repeatAfter >= .seconds(120))
        let url = try await harness.pages.serve("/page", "<title>Page</title>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        _ = try await agent.call("handoff", ["tab": "t1", "reason": "Pick the delivery slot you want"])
        try await waitFor { harness.notifier.posted.count == 2 }
        try await Task.sleep(for: .seconds(1))
        #expect(harness.notifier.posted.count == 2)
        #expect(Set(harness.notifier.posted.map(\.id)).count == 1)
    }

    /// A question with a few choices: the owner picks one (here from the
    /// notification's buttons), and the agent gets the pick.
    @Test func askReturnsTheOwnersPick() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent(waits: Self.quick)
        let choices: [AgentJSON] = ["Monday", "Tuesday", "Wednesday"]

        let call = Task {
            try await agent.call("ask", ["question": "Which day should the delivery come?", "choices": .array(choices)],
                                 progressToken: "q")
        }
        try await waitFor { !harness.notifier.posted.isEmpty }
        let notice = try #require(harness.notifier.posted.first)
        #expect(notice.body.contains("Which day should the delivery come?"))
        #expect(notice.choices == ["Monday", "Tuesday", "Wednesday"])
        let session = try #require(harness.server.sessions.all.first)
        #expect(harness.server.owner.needs(session))

        harness.server.owner.clicked(notice.id, action: AgentNotice.choiceAction(1))
        let answer = try await call.value
        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("Tuesday"))
        #expect(!answer.text.contains("Monday"))
        #expect(!harness.server.owner.needs(session))

        let tooMany = try await agent.call("ask", ["question": "Which?", "choices": ["a", "b", "c", "d", "e"]])
        #expect(tooMany.isError)
        #expect(tooMany.text.contains("four"))
    }

    /// A tab closed while the agent waits on the owner ends the wait, saying so.
    @Test func closingTheTabEndsItsHandoff() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/page", "<title>Page</title>")
        let agent = try await harness.agent(waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let call = Task { try await agent.call("handoff", ["tab": "t1", "reason": "Look at this"], progressToken: "c") }
        try await waitFor { !harness.server.owner.waiting.isEmpty }

        let tab = try #require(harness.agents?.tabs.first)
        harness.agents?.browser.close(tab.id, discarding: true)
        let answer = try await call.value
        #expect(answer.isError)
        #expect(answer.text.contains("t1 was closed"))
        #expect(harness.server.owner.waiting.isEmpty)
    }

    /// A Handoff the owner hasn't come to keeps its tab past cleanup, even
    /// once its agent stopped asking; it closes once the owner is done.
    @Test func cleanupKeepsATabWaitingOnTheOwner() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/page", "<title>Page</title>")
        let agent = try await harness.agent(client: "codex-mcp-client", waits: Self.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await agent.call("handoff", ["tab": "t1", "reason": "Confirm the address"])

        harness.clock.advance(by: .seconds(60 * 60))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.count == 1)

        harness.server.owner.done(try #require(harness.server.owner.waiting.first))
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.isEmpty == true)
    }

    /// The command line's exit codes: 3 while the owner is needed, apart
    /// from failing (1), Nerda unreachable (2) and timing out (124).
    @Test func theCommandLineExitsThreeWhileTheOwnerIsNeeded() {
        #expect(AgentReply.done("ok").exitCode == 0)
        #expect(AgentReply.failed(AgentError(.needsUser, "Ask the user")).exitCode == 3)
        #expect(AgentReply.failed(AgentError(.failed, "No")).exitCode == 1)
        #expect(AgentReply.failed(AgentError(.unreachable, "Closed")).exitCode == 2)
        #expect(AgentReply.failed(AgentError(.timedOut, "Slow")).exitCode == 124)
    }
}
