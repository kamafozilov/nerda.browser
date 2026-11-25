import Foundation
import Testing
import WebKit
@testable import Nerda

/// What agents look up beside pages (spec #119, ticket #141): a URL fetched
/// with the profile's cookies, the owner's history and bookmarks read and
/// left as they were, the profile signed in to a site, and the tool list
/// kept lean until an agent asks for more.
@MainActor
struct AgentLookupTests {
    /// An agent starts with the page verbs only; more_tools adds a group,
    /// and the client is told its tool list changed.
    @Test func moreToolsAddsAGroupAndTellsTheClient() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()

        let lean = try await agent.tools().compactMap { $0["name"]?.string }
        #expect(Set(["open", "navigate", "tabs", "close", "fetch", "more_tools"]).isSubset(of: Set(lean)))
        #expect(!lean.contains("history"))
        #expect(!lean.contains("bookmarks"))
        #expect(!lean.contains("profiles"))

        let groups = try await agent.call("more_tools")
        #expect(!groups.isError, "\(groups.text)")
        #expect(groups.text.contains("history"))
        #expect(groups.text.contains("bookmarks"))
        #expect(agent.notifications.methods.isEmpty)

        let added = try await agent.call("more_tools", ["group": "history"])
        #expect(!added.isError, "\(added.text)")
        #expect(added.text.contains("history"))
        #expect(agent.notifications.methods == ["notifications/tools/list_changed"])
        let more = try await agent.tools().compactMap { $0["name"]?.string }
        #expect(more.contains("history"))
        #expect(!more.contains("bookmarks"))

        // Asked again, nothing changes: the client isn't told twice.
        _ = try await agent.call("more_tools", ["group": "history"])
        #expect(agent.notifications.methods.count == 1)
        // A group that isn't there fails, naming the ones that are.
        let unknown = try await agent.call("more_tools", ["group": "nothing"])
        #expect(unknown.isError)
        #expect(unknown.text.contains("bookmarks"))
    }

    /// "That invoice page from last week": history search finds it, the
    /// bookmarks are read in their folders, and neither changes.
    @Test func historyAndBookmarksAnswerAndChangeNothing() async throws {
        let work = try temporaryProfile("Work")
        let harness = try AgentHarness(profiles: [work])
        defer { harness.close() }
        let now = Date.now
        work.history.visit(URL(string: "https://billing.example.com/invoices/42")!, title: "Invoice 42", at: now.addingTimeInterval(-3 * 86400))
        work.history.visit(URL(string: "https://billing.example.com/invoices/7")!, title: "Invoice 7", at: now.addingTimeInterval(-40 * 86400))
        work.history.visit(URL(string: "https://news.example.org/")!, title: "News", at: now.addingTimeInterval(-60))
        work.bookmarks.add(Bookmarks.Item(title: "Docs", url: URL(string: "https://docs.example.com/")!))
        work.bookmarks.add(Bookmarks.Item(title: "Bills", children: [
            Bookmarks.Item(title: "Power company", url: URL(string: "https://power.example.net/account")!),
        ]))
        let visits = work.history.visits, items = work.bookmarks.items
        let agent = try await harness.agent()

        let found = try await agent.call("history", ["query": "invoice", "days": 7, "profile": "work"])
        #expect(!found.isError, "\(found.text)")
        #expect(found.text.contains("https://billing.example.com/invoices/42"))
        #expect(found.text.contains("Invoice 42"))
        #expect(!found.text.contains("invoices/7"))
        #expect(!found.text.contains("News"))
        let latest = try await agent.call("history", ["profile": "Work", "limit": 1])
        #expect(latest.text.contains("https://news.example.org/"))
        #expect(!latest.text.contains("Invoice"))
        let none = try await agent.call("history", ["query": "nothing like it", "profile": "Work"])
        #expect(!none.isError)
        #expect(none.text.contains("No pages"))

        let all = try await agent.call("bookmarks", ["profile": "Work"])
        #expect(!all.isError, "\(all.text)")
        #expect(all.text.contains("Docs  https://docs.example.com/"))
        #expect(all.text.contains("Bills/"))
        #expect(all.text.contains("Power company  https://power.example.net/account"))
        let power = try await agent.call("bookmarks", ["query": "power", "profile": "Work"])
        #expect(power.text.contains("Bills / Power company"))
        #expect(!power.text.contains("Docs"))

        // A profile there isn't fails, naming the ones there are.
        let missing = try await agent.call("history", ["profile": "Home"])
        #expect(missing.isError)
        #expect(missing.text.contains("Work"))

        // Read, and left as they were; the agent's reading made no tab either.
        #expect(work.history.visits == visits)
        #expect(work.bookmarks.items == items)
        #expect(harness.agents?.tabs.isEmpty ?? true)
        let tools = try await agent.tools()
        for name in ["history", "bookmarks"] {
            // Not listed yet, and still there to call.
            #expect(!tools.contains { $0["name"]?.string == name })
        }
    }

    /// An agent reads a signed-in page without a tab: the request carries
    /// the profile's cookies, and the body comes back, its length capped.
    @Test func fetchReadsASignedInPageWithTheProfilesCookies() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let me = try await harness.pages.serve("/api/me", #"{"name":"Kamron","signedIn":true}"#)
        let long = try await harness.pages.serve("/long", String(repeating: "word ", count: 20_000))
        try await signIn(harness.server.agents(for: .main), at: me, cookie: "session", "abc123")
        let agent = try await harness.agent()

        let answer = try await agent.call("fetch", ["url": AgentJSON(me)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("status: 200"))
        #expect(answer.text.contains(#""signedIn":true"#))
        #expect(answer.text.contains("<page-text"))
        let request = try #require(harness.pages.requests(for: "/api/me").first)
        #expect(request.contains("session=abc123"))
        // No tab for it.
        #expect(harness.agents?.tabs.isEmpty == true)

        let capped = try await agent.call("fetch", ["url": AgentJSON(long)])
        #expect(!capped.isError)
        #expect(capped.text.contains("more characters"))
        #expect(capped.text.count < 45_000)
        let missing = try await agent.call("fetch", ["url": AgentJSON(try await harness.pages.url("/gone"))])
        #expect(!missing.isError)
        #expect(missing.text.contains("status: 404"))
        let started = ContinuousClock.now
        let nowhere = try await agent.call("fetch", ["url": "http://nothing-here.invalid/"])
        #expect(nowhere.isError)
        #expect(nowhere.text.contains("couldn't be fetched"))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// Signed in to a site in Work only: the agent asks which profile is,
    /// and opens its tab there, signed in.
    @Test func anAgentFindsAndUsesTheProfileSignedInToASite() async throws {
        let work = try temporaryProfile("Work")
        let harness = try AgentHarness(profiles: [work])
        defer { harness.close() }
        let account = try await harness.pages.serve("/account", "<title>Account</title><p>Your account</p>")
        try await signIn(harness.server.agents(for: work), at: account, cookie: "user_session", "w0rk")
        try await signIn(harness.server.agents(for: .main), at: account, cookie: "_ga", "tracker")
        let agent = try await harness.agent()
        _ = try await agent.call("more_tools", ["group": "profiles"])

        let which = try await agent.call("profiles", ["site": AgentJSON(account)])

        #expect(!which.isError, "\(which.text)")
        let lines = which.text.split(separator: "\n").map(String.init)
        let workLine = try #require(lines.firstIndex { $0.hasPrefix("Work:") })
        let personalLine = try #require(lines.firstIndex { $0.hasPrefix("Personal:") })
        #expect(lines[workLine].contains("signed in"))
        #expect(!lines[personalLine].contains("likely signed in"))
        #expect(workLine < personalLine)

        let opened = try await agent.call("open", ["url": AgentJSON(account), "profile": "Work"])
        #expect(!opened.isError, "\(opened.text)")
        #expect(opened.text.contains("Your account"))
        #expect(harness.pages.requests(for: "/account").last?.contains("user_session=w0rk") == true)
        #expect(harness.server.agents(for: work).tabs.count == 1)
        #expect(harness.server.agents(for: .main).tabs.isEmpty)
        // Its name works like any other Agent tab's.
        #expect(try await agent.call("tabs").text.contains("t1"))
    }

    /// A sign-in cookie for `url`'s site in the Agent browser's store, as
    /// signing in there leaves.
    private func signIn(_ agents: AgentBrowser, at url: URL, cookie name: String, _ value: String) async throws {
        let host = try #require(url.host())
        let cookie = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: name, .value: value,
            .expires: Date.now.addingTimeInterval(86400),
        ]))
        await agents.browser.dataStore.httpCookieStore.setCookie(cookie)
    }
}
