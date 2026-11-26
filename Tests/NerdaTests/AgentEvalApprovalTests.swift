import Foundation
import Testing
import WebKit
@testable import Nerda

/// Every agent `eval` waits for the owner's Allow (decision #43): its guard
/// is a fence, not a sandbox, as a `javascript:` address set through
/// `location` runs in the page's own world and `fetch` reaches the site
/// with the owner's cookies. The owner is shown the agent, the tab, the
/// site and the script whole; one Allow runs that script on that tab once.
/// The owner here is a `TestAllower`: no sheet shows.
@MainActor
struct AgentEvalApprovalTests {
    /// Unapproved, eval runs nothing: the agent hears needs_user, the owner
    /// is told and shown the script; calling again attaches to the same
    /// request, and once they allow it, it runs.
    @Test func evalWaitsForTheOwnersAllowAndRunsAfterIt() async throws {
        let owner = TestAllower()
        let harness = try AgentHarness(approveScript: owner.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/notes", "<title>Notes</title><p id=count>0</p>")
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let script = "document.querySelector('#count').textContent = '1'; return 'ran'"

        let held = try await agent.call("eval", ["tab": "t1", "script": .string(script)])

        #expect(!held.isError, "needs_user is no failure: \(held.text)")
        #expect(held.text.contains("needs_user"), "\(held.text)")
        #expect(try await count(harness) == "0")
        let card = try #require(owner.shown.first)
        #expect(card.asker == "Claude")
        #expect(card.tab == "t1")
        #expect(card.site.hasPrefix("127.0.0.1:"), "\(card.site)")
        #expect(card.script == script)
        #expect(harness.server.owner.waiting.count == 1)
        #expect(harness.notifier.posted.contains { $0.title == "Claude wants to run a script" })

        let again = try await agent.call("eval", ["tab": "t1", "script": .string(script)])
        #expect(again.text.contains("needs_user"), "\(again.text)")
        #expect(owner.shown.count == 1, "the same request, not a second")
        #expect(harness.server.owner.waiting.count == 1)

        let call = Task { try await agent.call("eval", ["tab": "t1", "script": .string(script)], progressToken: "p1") }
        try await waitFor { !agent.notifications.progress.isEmpty }
        #expect(try await count(harness) == "0")
        owner.verdict = true
        let ran = try await call.value

        #expect(!ran.isError, "\(ran.text)")
        #expect(ran.text.contains("ran"), "\(ran.text)")
        #expect(try await count(harness) == "1")
        #expect(harness.server.owner.waiting.isEmpty)
        #expect(owner.shown.count == 1)
    }

    /// Don't Allow fails the call, saying so, and runs nothing; the agent
    /// hears it once, and the same script asked again is a new request.
    @Test func dontAllowRefusesTheScript() async throws {
        let owner = TestAllower()
        let harness = try AgentHarness(approveScript: owner.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/notes", "<title>Notes</title><p id=count>0</p>")
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let script = "document.querySelector('#count').textContent = '1'"

        let call = Task { try await agent.call("eval", ["tab": "t1", "script": .string(script)], progressToken: "p1") }
        try await waitFor { owner.shown.count == 1 }
        owner.verdict = false
        let refused = try await call.value

        #expect(refused.isError)
        #expect(refused.text.contains("didn't allow"), "\(refused.text)")
        #expect(try await count(harness) == "0")
        #expect(harness.server.owner.waiting.isEmpty)

        let again = try await agent.call("eval", ["tab": "t1", "script": .string(script)])
        #expect(again.text.contains("needs_user"), "\(again.text)")
        #expect(owner.shown.count == 2)
        #expect(try await count(harness) == "0")
    }

    /// An Allow is for that script on that tab and site, once: another
    /// script, the same one run a second time, the same one in another tab
    /// or after the tab went to another site each ask again.
    @Test func anAllowIsForThatScriptThereOnce() async throws {
        let owner = TestAllower()
        let harness = try AgentHarness(approveScript: owner.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/notes", "<title>Notes</title><p id=count>0</p>")
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let add = "const p = document.querySelector('#count'); p.textContent = Number(p.textContent) + 1; return p.textContent"

        let first = Task { try await agent.call("eval", ["tab": "t1", "script": .string(add)], progressToken: "p1") }
        try await waitFor { owner.shown.count == 1 }
        owner.verdict = true
        let ran = try await first.value
        #expect(!ran.isError, "\(ran.text)")
        #expect(try await count(harness)?.split(separator: " ").sorted() == ["0", "1"])

        let other = try await agent.call("eval", ["tab": "t1", "script": "return document.title"])
        #expect(other.text.contains("needs_user"), "another script: \(other.text)")
        let second = try await agent.call("eval", ["tab": "t1", "script": .string(add)])
        #expect(second.text.contains("needs_user"), "a second run: \(second.text)")
        let elsewhere = try await agent.call("eval", ["tab": "t2", "script": .string(add)])
        #expect(elsewhere.text.contains("needs_user"), "another tab: \(elsewhere.text)")
        #expect(try await count(harness)?.split(separator: " ").sorted() == ["0", "1"])
        #expect(owner.shown.count == 4)
        #expect(owner.shown.map(\.tab) == ["t1", "t1", "t1", "t2"])

        // Allowed on one site, the tab gone to another before the call came
        // again: asked anew there, the sheet for the first taken away.
        let site = try await harness.pages.serve("/notes", "<title>Notes</title><p id=count>0</p>", host: "localhost")
        _ = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(site)])
        let moved = try await agent.call("eval", ["tab": "t1", "script": .string(add)])
        #expect(moved.text.contains("needs_user"), "\(moved.text)")
        #expect(owner.shown.last?.site.hasPrefix("localhost:") == true, "\(owner.shown.last?.site ?? "")")
        #expect(harness.server.owner.waiting.count == 3)
    }

    /// A script longer than the owner can read is refused before anyone is
    /// asked.
    @Test func aLongScriptIsRefusedUnasked() async throws {
        let owner = TestAllower()
        let harness = try AgentHarness(approveScript: owner.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/notes", "<title>Notes</title>")
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let long = "return 1;" + String(repeating: " ", count: AgentEval.mostScript)
        let refused = try await agent.call("eval", ["tab": "t1", "script": .string(long)])

        #expect(refused.isError)
        #expect(refused.text.contains("at most"), "\(refused.text)")
        #expect(owner.shown.isEmpty)
        #expect(harness.server.owner.waiting.isEmpty)
    }

    /// eval in a run asks as eval does: the run answers needs_user at that
    /// step, and once the owner allowed it the same run goes through.
    @Test func evalInARunAsksToo() async throws {
        let owner = TestAllower()
        let harness = try AgentHarness(approveScript: owner.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/notes", "<title>Notes</title><p id=count>0</p>")
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let run = """
            const title = nerda.eval("t1", "return document.title");
            print("got " + title);
            """

        let held = try await agent.call("run", ["script": .string(run)])

        #expect(!held.isError, "needs_user is no failure: \(held.text)")
        #expect(held.text.contains("needs_user"), "\(held.text)")
        #expect(owner.shown.map(\.script) == ["return document.title"])
        owner.verdict = true
        try await waitFor { harness.server.owner.waiting.isEmpty }

        let ran = try await agent.call("run", ["script": .string(run)])
        #expect(!ran.isError, "\(ran.text)")
        #expect(ran.text.contains("got eval ran in t1"), "\(ran.text)")
        #expect(owner.shown.count == 1)

        let again = try await agent.call("run", ["script": .string(run)])
        #expect(again.text.contains("needs_user"), "each run's eval asks: \(again.text)")
        #expect(owner.shown.count == 2)
    }

    /// The sheet shows what would hide in a script, such as a mark turning
    /// text round, as an escape; lines, tabs and letters as they are.
    @Test func theSheetShowsHiddenCharacters() {
        let script = "const a = 1;\n\tif (ok\u{202E} ) {}\u{200B} // привет"
        #expect(AgentEvalApprovals.visible(script) == "const a = 1;\n\tif (ok\\u{202E} ) {}\\u{200B} // привет")
    }

    /// What the page's counter says, in each Agent tab, joined: "1 0".
    private func count(_ harness: AgentHarness) async throws -> String? {
        var counts: [String] = []
        for tab in harness.agents?.browser.tabs ?? [] {
            let page = try #require(tab.page)
            counts.append(try await page.evaluateJavaScript("document.querySelector('#count').textContent") as? String ?? "")
        }
        return counts.joined(separator: " ")
    }
}

/// The owner looking at eval's card: records each card, and answers it
/// once `verdict` is set (then waits for the next).
@MainActor
final class TestAllower {
    private(set) var shown: [ScriptCard] = []
    var verdict: Bool?

    var approve: AgentEvalApprovals.Approve {
        { [self] card in
            shown.append(card)
            while verdict == nil {
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(50))
            }
            defer { verdict = nil }
            return verdict
        }
    }
}
