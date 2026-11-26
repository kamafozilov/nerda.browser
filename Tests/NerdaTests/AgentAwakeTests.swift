import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agent tabs kept running while their agent works, how many stay awake,
/// and screenshots of them (spec #119, ticket #135).
@MainActor
struct AgentAwakeTests {
    /// A page that keeps the time of each of its animation frames and each
    /// tick of its 50 ms timer, on its own clock, and says whether it
    /// thinks it is seen.
    static let running = """
        <title>Running</title>
        <script>
        window.drawn = []; window.ticks = [];
        const keep = (times) => { times.push(performance.now()); if (times.length > 600) times.shift(); };
        function frame() { keep(drawn); requestAnimationFrame(frame); }
        requestAnimationFrame(frame);
        setInterval(() => keep(ticks), 50);
        </script>
        <p>Counting</p>
        """

    /// The most frames and ticks the page had in any one second of those it
    /// kept, and whether it counts as seen.
    private func looked(_ tab: Nerda.Tab) async throws -> (frames: Int, ticks: Int, visible: Bool) {
        let page = try #require(tab.page)
        let read = """
            const most = (times) => {
                let best = 0;
                for (let i = 0, j = 0; i < times.length; i++) {
                    while (j < times.length && times[j] - times[i] < 1000) j++;
                    best = Math.max(best, j - i);
                }
                return best;
            };
            return [most(drawn), most(ticks), document.visibilityState];
            """
        let values = try #require(try await page.callAsyncJavaScript(read, contentWorld: .page) as? [Any])
        return (values[0] as? Int ?? 0, values[1] as? Int ?? 0, values[2] as? String == "visible")
    }

    /// While its agent works, an Agent tab runs as a page on screen would:
    /// it counts as seen, and in a second it has more than twenty animation
    /// frames and more than ten ticks of its timer. A page out of sight gets
    /// no frames, and WebKit holds its timers to a second or more apart. The
    /// page times itself, on its own clock, and any one second of its own
    /// will do: a busy Mac may slow some seconds, not every one. (In Low
    /// Power Mode WebKit draws a page 30 times a second, still more than twenty.)
    @Test func aWorkingAgentsTabRunsAtFullSpeed() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/running", Self.running)
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)
        let tab = try #require(harness.agents?.tabs.first)

        #expect(try await looked(tab).visible)
        var seen = (frames: 0, ticks: 0, visible: false)
        do {
            try await waitFor("More than twenty frames and ten ticks in a second") {
                seen = try await looked(tab)
                return seen.frames > 20 && seen.ticks > 10
            }
        } catch {
            Issue.record("at most \(seen.frames) frames and \(seen.ticks) ticks in a second")
            throw error
        }
        #expect(try await looked(tab).visible)
    }

    /// While its agent works, no rule puts an Agent tab to sleep: not the
    /// owner's sleep setting, not memory pressure. About two minutes after
    /// the agent's last request it is a page out of sight again, under the
    /// same rules as the owner's.
    @Test func aWorkingAgentsTabsDontSleepAndFallBackOnceIdle() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.awake.idleAfter = .milliseconds(800)
        let url = try await harness.pages.serve("/running", Self.running)
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)
        let browser = try #require(harness.agents?.browser)
        let tab = try #require(browser.tabs.first)
        // Out of sight for as long as any rule waits.
        tab.lastSeen = .distantPast
        let rules = SleepCoordinator(watchingSystem: false)
        rules.lookEvery = .milliseconds(50)
        rules.register(browser)

        rules.pressure(.critical)
        browser.sleepIdleTabs(unseenFor: 0, pinsToo: true)
        try await Task.sleep(for: .milliseconds(300))
        rules.pressure(.normal)
        #expect(!tab.isAsleep)

        // The agent quiet: a page out of sight, which the rules may put to sleep.
        try await waitFor {
            try await tab.page?.callAsyncJavaScript("return document.visibilityState", contentWorld: .page) as? String == "hidden"
        }
        browser.sleepIdleTabs(unseenFor: 0, pinsToo: true)
        try await waitFor { tab.isAsleep }
    }

    /// The Mac's memory decides how many Agent tabs stay awake: about a
    /// quarter of it in GB, never fewer than 6 nor more than 16.
    @Test func theAwakeCapFollowsMemory() {
        let gigabyte: UInt64 = 1 << 30
        #expect(AgentAwake.cap(memory: 8 * gigabyte) == 6)
        #expect(AgentAwake.cap(memory: 16 * gigabyte) == 6)
        #expect(AgentAwake.cap(memory: 32 * gigabyte) == 8)
        #expect(AgentAwake.cap(memory: 48 * gigabyte) == 12)
        #expect(AgentAwake.cap(memory: 64 * gigabyte) == 16)
        #expect(AgentAwake.cap(memory: 128 * gigabyte) == 16)
    }

    /// Past the cap, the Agent tab longest unused goes to sleep, whichever
    /// session's it is; asked for again, it wakes where it was, and another
    /// sleeps in its place.
    @Test func noMoreAgentTabsStayAwakeThanTheCap() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.awake.cap = 2
        let claude = try await harness.agent(client: "claude-code", session: "one")
        let codex = try await harness.agent(client: "codex-mcp-client", session: "two")
        for (n, agent) in [claude, claude, codex].enumerated() {
            let url = try await harness.pages.serve("/\(n + 1)", "<title>Page \(n + 1)</title><p>Page \(n + 1)</p>")
            #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)
        }
        let tabs = try #require(harness.agents?.tabs)
        let awake = { Set(tabs.filter { !$0.isAsleep }.map(\.title)) }
        #expect(tabs.count == 3)
        #expect(awake() == ["Page 2", "Page 3"] as Set)

        let again = try await claude.call("navigate", ["tab": "t1", "url": AgentJSON(try await harness.pages.url("/1"))])

        #expect(again.text.contains("Page 1"), "\(again.text)")
        #expect(awake() == ["Page 1", "Page 3"] as Set)
    }

    /// A tab the owner took over, or watches, is theirs to use: the cap
    /// never puts it to sleep under them, however long the agent left it.
    @Test func theCapSparesATabTheOwnerTookOverOrWatches() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.awake.cap = 2
        let agent = try await harness.agent()
        for n in 1...2 {
            let url = try await harness.pages.serve("/\(n)", "<title>Page \(n)</title><p>Page \(n)</p>")
            #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)
        }
        let session = try #require(harness.server.sessions.all.first)
        let first = try #require(harness.server.openTabs(of: session).first { $0.ref == "t1" })
        harness.server.takeOver(first)
        let third = try await harness.pages.serve("/3", "<title>Page 3</title><p>Page 3</p>")

        #expect(try await agent.call("open", ["url": AgentJSON(third)]).isError == false)

        #expect(!first.tab.isAsleep)
        harness.server.handBack(first)
        first.agents.watched.insert(first.tab.id)
        let fourth = try await harness.pages.serve("/4", "<title>Page 4</title><p>Page 4</p>")
        #expect(try await agent.call("open", ["url": AgentJSON(fourth)]).isError == false)
        #expect(!first.tab.isAsleep)
        first.agents.watched.remove(first.tab.id)
    }

    /// A page of two halves, red and blue, that counts the clicks on each.
    static let halves = """
        <title>Halves</title>
        <style>
        html, body { margin: 0; height: 100%; }
        div { position: fixed; top: 0; bottom: 0; width: 50%; }
        #left { left: 0; background: rgb(255, 0, 0); }
        #right { right: 0; background: rgb(0, 0, 255); }
        </style>
        <div id="left"></div><div id="right"></div>
        <script>
        window.clicks = [];
        for (const id of ['left', 'right']) {
            document.getElementById(id).addEventListener('click', e => clicks.push(id + (e.isTrusted ? ' trusted' : ' script')));
        }
        </script>
        """

    /// The image a tool answered with, decoded, and its text.
    private func shot(_ agent: AgentTestClient, _ arguments: [String: AgentJSON]) async throws -> (image: NSBitmapImageRep, text: String) {
        let reply = try await agent.request("tools/call", ["name": "screenshot", "arguments": .object(arguments)])
        let content = try #require(reply["result"]?["content"]?.array, "\(reply.line)")
        let text = content.compactMap { $0["text"]?.string }.joined(separator: "\n")
        #expect(reply["result"]?["isError"]?.bool == false, "\(text)")
        let image = try #require(content.first { $0["type"]?.string == "image" }, "No image: \(text)")
        #expect(image["mimeType"]?.string == "image/jpeg")
        let base64 = try #require(image["data"]?.string)
        let data = try #require(Data(base64Encoded: base64))
        return (try #require(NSBitmapImageRep(data: data)), text)
    }

    /// Whether the pixel at `x`, `y` (from the top left) is mostly red or mostly blue.
    private func color(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> String {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "none" }
        if color.redComponent > 0.8, color.blueComponent < 0.3 { return "red" }
        if color.blueComponent > 0.8, color.redComponent < 0.3 { return "blue" }
        return "other (\(color))"
    }

    /// An Agent tab is never on screen, yet its screenshot shows its page:
    /// 1024 pixels wide by default, at full resolution when asked.
    @Test func aScreenshotOfAnOffScreenAgentTabShowsThePage() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/halves", Self.halves)
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)

        let small = try await shot(agent, ["tab": "t1"])

        #expect(small.image.pixelsWide == 1024)
        #expect(small.image.pixelsHigh == 640)
        #expect(color(small.image, 256, 320) == "red")
        #expect(color(small.image, 768, 320) == "blue")
        #expect(small.text.contains("t1"))

        let full = try await shot(agent, ["tab": "t1", "full": true])

        #expect(full.image.pixelsWide >= 1280)
        #expect(full.image.pixelsHigh * 1280 == full.image.pixelsWide * 800)
        #expect(color(full.image, full.image.pixelsWide / 4, full.image.pixelsHigh / 2) == "red")
        #expect(color(full.image, full.image.pixelsWide * 3 / 4, full.image.pixelsHigh / 2) == "blue")
    }

    /// A screenshot shows secret fields masked, as the outline does: a card
    /// number typed in a plain text box, or a password a page shows as
    /// text, is drawn as dots in the picture, whatever its digits; other
    /// boxes as they are. The page's own style is back after.
    @Test func aScreenshotMasksSecretFields() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/pay", """
            <title>Pay</title>
            <style>input { font: 40px monospace; width: 900px; display: block; margin: 20px; }</style>
            <input id=card name=cardnumber value="4111111111111111">
            <input id=shown aria-label=Password value="hunter2hunter2">
            <input id=name name=fullname value="Jane Example">
            """)
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)
        let page = try #require(harness.agents?.tabs.first?.page)
        func set(_ id: String, _ value: String) async throws {
            _ = try await page.callAsyncJavaScript("document.getElementById(id).value = value",
                                                   arguments: ["id": id, "value": value], contentWorld: .page)
        }

        let first = try await shot(agent, ["tab": "t1"]).image
        try await set("card", "5555555555554444")
        try await set("shown", "swordfish12345")
        let secretsChanged = try await shot(agent, ["tab": "t1"]).image
        try await set("name", "John Other")
        let nameChanged = try await shot(agent, ["tab": "t1"]).image

        #expect(first.representation(using: .png, properties: [:]) == secretsChanged.representation(using: .png, properties: [:]),
                "the secret fields' characters show in the picture")
        #expect(secretsChanged.representation(using: .png, properties: [:]) != nameChanged.representation(using: .png, properties: [:]),
                "a plain box's change shows")
        let style = try await page.callAsyncJavaScript(
            "return getComputedStyle(document.getElementById('card')).webkitTextSecurity", contentWorld: .page) as? String
        #expect(style == "none")
    }

    /// A point in the screenshot is where the click lands: on the element
    /// drawn there, as a person's click.
    @Test func aClickAtAPointOfTheScreenshotLandsOnWhatIsThere() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/halves", Self.halves)
        let agent = try await harness.agent()
        #expect(try await agent.call("open", ["url": AgentJSON(url)]).isError == false)
        let shot = try await shot(agent, ["tab": "t1"])
        #expect(color(shot.image, 900, 100) == "blue")
        let page = try #require(harness.agents?.tabs.first?.page)
        let clicks = { try await page.callAsyncJavaScript("return window.clicks", contentWorld: .page) as? [String] }

        let right = try await agent.call("click_at", ["tab": "t1", "x": 900, "y": 100])

        #expect(!right.isError, "\(right.text)")
        try await waitFor { try await clicks() == ["right trusted"] }

        // In a full-resolution screenshot's pixels when said so.
        let wide = try await self.shot(agent, ["tab": "t1", "full": true]).image.pixelsWide
        let left = try await agent.call("click_at", ["tab": "t1", "x": .number(Double(wide / 8)), "y": 50, "full": true])

        #expect(!left.isError, "\(left.text)")
        try await waitFor { try await clicks() == ["right trusted", "left trusted"] }
    }
}
