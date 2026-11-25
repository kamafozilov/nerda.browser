import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents click with real input (spec #119, ticket #136): the page sees a
/// person's click, a covered element is refused with the overlay's buttons
/// named, and the answer says what the click changed.
@MainActor
struct AgentClickTests {
    /// The element is scrolled into view and gets the mouse's own click:
    /// the page sees a trusted event.
    @Test func aClickArrivesAsAPersonsClick() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/far", """
            <title>Far</title>
            <script>window.clicks = []; document.addEventListener('click', (e) => clicks.push((e.isTrusted ? 'trusted ' : 'script ') + e.target.id));</script>
            <div style="height: 3000px"></div>
            <button id=send>Send</button>
            <div style="height: 3000px"></div>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let send = try #require(try await ref(of: #"button "Send""#, agent), "no Send button")

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(send)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(try await clicks(harness) == ["trusted send"])
    }

    /// A banner over the element takes the click a person would make: the
    /// click is refused, naming the banner's buttons, and nothing is clicked.
    /// Once the banner is closed through one of them, the click goes through.
    @Test func aCoveredElementIsRefusedNamingTheOverlaysButtons() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/banner", """
            <title>Shop</title>
            <script>window.clicks = []; document.addEventListener('click', (e) => clicks.push(e.target.id));</script>
            <button id=buy style="margin: 200px">Add to basket</button>
            <div id=banner style="position: fixed; inset: 0; background: white">
              <p>We use cookies</p>
              <button id=accept onclick="banner.remove()">Accept all</button>
              <button id=reject onclick="banner.remove()">Reject all</button>
            </div>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        let buy = try #require(Self.ref(of: #"button "Add to basket""#, in: outline), "\(outline)")
        let accept = try #require(Self.ref(of: #"button "Accept all""#, in: outline), "\(outline)")
        let reject = try #require(Self.ref(of: #"button "Reject all""#, in: outline), "\(outline)")

        let refused = try await agent.call("click", ["tab": "t1", "ref": .string(buy)])

        #expect(refused.isError)
        #expect(refused.text.contains("covered"), "\(refused.text)")
        #expect(refused.text.contains(#"\#(accept) button "Accept all""#), "\(refused.text)")
        #expect(refused.text.contains(#"\#(reject) button "Reject all""#), "\(refused.text)")
        #expect(try await clicks(harness) == [])

        let closed = try await agent.call("click", ["tab": "t1", "ref": .string(accept)])
        #expect(!closed.isError, "\(closed.text)")
        let bought = try await agent.call("click", ["tab": "t1", "ref": .string(buy)])

        #expect(!bought.isError, "\(bought.text)")
        #expect(try await clicks(harness) == ["accept", "buy"])
    }

    /// After the click the page is let settle, even when it changes a while
    /// later, and the answer lists by ref what came, went and changed, and
    /// nothing that stayed as it was.
    @Test func theAnswerListsWhatCameWentOrChanged() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/cart", """
            <title>Cart</title>
            <label>Quantity <input id=quantity value=1></label>
            <button id=promo>Apply promo</button>
            <a href="/help">Help</a>
            <button id=add onclick="setTimeout(() => {
                quantity.value = 2;
                promo.remove();
                document.body.insertAdjacentHTML('beforeend', '<button>Check out</button>');
            }, 100)">Add one</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        let add = try #require(Self.ref(of: #"button "Add one""#, in: outline), "\(outline)")
        let promo = try #require(Self.ref(of: #"button "Apply promo""#, in: outline), "\(outline)")
        let quantity = try #require(Self.ref(of: #"textbox "Quantity""#, in: outline), "\(outline)")

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(add)]).text

        #expect(answer.hasPrefix(#"clicked \#(add) button "Add one""#), "\(answer)")
        #expect(answer.contains("tab: t1"), "\(answer)")
        let came = try #require(section("came", of: answer), "\(answer)")
        let went = try #require(section("went", of: answer), "\(answer)")
        let changed = try #require(section("changed", of: answer), "\(answer)")
        #expect(came.count == 1 && came[0].contains(#"button "Check out""#), "\(answer)")
        #expect(went == [#"- \#(promo) button "Apply promo""#], "\(answer)")
        #expect(changed.count == 1 && changed[0].hasPrefix(#"- \#(quantity) textbox "Quantity" = "2""#), "\(answer)")
        #expect(!answer.contains("Help"), "\(answer)")
    }

    /// A click that takes the tab to another page answers with that page,
    /// as open would: its address, outline and the start of its text.
    @Test func aClickThatNavigatesAnswersTheNewPage() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let next = try await harness.pages.serve("/next", "<title>Next</title><p>Welcome to the next page</p><button>Go on</button>")
        let url = try await harness.pages.serve("/start", "<title>Start</title><a href=\"\(next.path)\">Next page</a>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let link = try #require(try await ref(of: #"link "Next page""#, agent))

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(link)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("address: \(next.absoluteString)"), "\(answer.text)")
        #expect(answer.text.contains("title: Next"), "\(answer.text)")
        #expect(answer.text.contains(#"button "Go on""#), "\(answer.text)")
        #expect(answer.text.contains("Welcome to the next page"), "\(answer.text)")
    }

    /// A click on a link to a new window opens it as another of the
    /// session's Agent tabs, and the answer names it.
    @Test func aClickThatOpensANewTabSaysSo() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let other = try await harness.pages.serve("/other", "<title>Other</title><p>Another tab</p>")
        let url = try await harness.pages.serve("/links", "<title>Links</title><a href=\"\(other.path)\" target=_blank>Elsewhere</a>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let link = try #require(try await ref(of: #"link "Elsewhere""#, agent))

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(link)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("notice: opened a new tab t2"), "\(answer.text)")
        let tabs = try await agent.call("tabs").text
        #expect(tabs.contains("t2"), "\(tabs)")
        try await waitFor { try await agent.call("text", ["tab": "t2"]).text.contains("Another tab") }
        // Another session sees none of it.
        let stranger = try await harness.agent(session: "session-2")
        #expect(try await stranger.call("text", ["tab": "t2"]).isError)
    }

    /// A click that raises a dialog says so, with its words, rather than
    /// waiting on a page that can't answer while the dialog is up.
    @Test func aClickThatRaisesADialogSaysSo() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/delete", """
            <title>Delete</title>
            <button onclick="if (confirm('Delete the draft?')) document.title = 'Deleted'">Delete</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let delete = try #require(try await ref(of: #"button "Delete""#, agent))

        let started = ContinuousClock.now
        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(delete)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("notice:"), "\(answer.text)")
        #expect(answer.text.contains("Delete the draft?"), "\(answer.text)")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A click at a point of the screenshot answers as a click on a ref
    /// does: with what it changed.
    @Test func aClickAtAPointAnswersWithWhatChanged() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/canvas", """
            <title>Canvas</title>
            <canvas id=map width=1280 height=800 style="position: fixed; inset: 0"></canvas>
            <script>map.addEventListener('click', (e) => document.body.insertAdjacentHTML('beforeend',
                `<button style="position: relative">Pin at ${e.clientX < 640 ? 'left' : 'right'}</button>`))</script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let answer = try await agent.call("click_at", ["tab": "t1", "x": 900, "y": 100])

        #expect(!answer.isError, "\(answer.text)")
        let came = try #require(section("came", of: answer.text), "\(answer.text)")
        #expect(came.count == 1 && came[0].contains(#"button "Pin at right""#), "\(answer.text)")
    }

    /// An element in a frame from another site, lower down the page, gets
    /// the mouse's own click at the right place.
    @Test func anElementInAFrameFromAnotherSiteGetsAPersonsClick() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        try await harness.pages.serve("/widget", """
            <title>Widget</title>
            <script>window.clicks = []; document.addEventListener('click', (e) => clicks.push((e.isTrusted ? 'trusted ' : 'script ') + e.target.id));</script>
            <div style="height: 900px"></div>
            <button id=pay>Choose plan</button>
            """)
        let widget = try await harness.pages.url("/widget", host: "localhost")
        let url = try await harness.pages.serve("/shop", """
            <title>Shop</title>
            <div style="height: 1500px"></div>
            <iframe title=Payment src="\(widget)" style="width: 600px; height: 400px; border: 7px solid; padding: 5px"></iframe>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        var outline = ""
        try await waitFor {
            outline = try await agent.call("snapshot", ["tab": "t1"]).text
            return outline.contains("Choose plan")
        }
        let pay = try #require(Self.ref(of: #"button "Choose plan""#, in: outline), "\(outline)")
        #expect(pay.hasPrefix("f"))

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(pay)])

        #expect(!answer.isError, "\(answer.text)")
        let frame = try #require(await frameClicks(harness))
        #expect(frame == ["trusted pay"], "\(answer.text)")
    }

    // MARK: - Helpers

    /// The lines under `came:`, `went:` or `changed:` in an answer.
    private func section(_ name: String, of answer: String) -> [String]? {
        let lines = answer.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(of: name + ":") else { return nil }
        return Array(lines[(start + 1)...].prefix { $0.hasPrefix("- ") })
    }

    /// The clicks the first frame from another site heard.
    private func frameClicks(_ harness: AgentHarness) async throws -> [String]? {
        let page = try page(harness)
        let frames = await AgentPage.frames(of: page)
        guard let frame = frames?.children.first?.info else { return nil }
        return try await page.callAsyncJavaScript("return window.clicks", in: frame, contentWorld: .page) as? [String]
    }

    /// The ref of the first outline line naming `element`, from a fresh snapshot.
    private func ref(of element: String, _ agent: AgentTestClient, tab: String = "t1") async throws -> String? {
        let outline = try await agent.call("snapshot", ["tab": .string(tab)]).text
        return Self.ref(of: element, in: outline)
    }

    static func ref(of element: String, in outline: String) -> String? {
        outline.split(separator: "\n").first { $0.contains(" " + element) }
            .flatMap { $0.firstMatch(of: #/^\s*- ((?:f\d+)?e\d+) /#) }
            .map { String($0.output.1) }
    }

    private func page(_ harness: AgentHarness) throws -> WKWebView {
        try #require(harness.agents?.tabs.first?.page)
    }

    private func clicks(_ harness: AgentHarness) async throws -> [String] {
        try await page(harness).callAsyncJavaScript("return window.clicks", contentWorld: .page) as? [String] ?? []
    }
}
