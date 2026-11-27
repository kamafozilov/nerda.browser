import Foundation
import Network
import Testing
import WebKit
@testable import Nerda

/// Serves a page that hears a stream of events, ten a second, as a chat or
/// a dashboard hears its server, and keeps the time of each one heard and
/// each tick of its own 100 ms timer. The page answers each event it hears
/// with a request of its own, which the server keeps the time of: what the
/// page did is known without asking the page, which would wake it. On a
/// queue of its own, so a busy main thread in other tests never holds the
/// stream up.
private final class StreamServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "HiddenPagesTests.stream")
    private let timer: DispatchSourceTimer
    /// Only on `queue`.
    private var streams: [NWConnection] = []
    /// When the page answered an event, only on `queue`.
    private var answers: [Date] = []

    static let page = """
        <script>
        window.heard = []; window.ticked = [];
        new EventSource('/events').onmessage = () => {
            heard.push(Date.now());
            fetch('/heard', {cache: 'no-store'}).catch(() => {});
        };
        setInterval(() => ticked.push(Date.now()), 100);
        </script>
        """

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        timer = DispatchSource.makeTimerSource(queue: queue)
        // Weak: requests the page sent may come in after the test has ended.
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self else { return connection.cancel() }
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                if request.hasPrefix("GET /events") {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                    streams.append(connection)
                } else if request.hasPrefix("GET /heard") {
                    answers.append(Date())
                    let head = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    let body = Data(Self.page.utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for stream in streams { stream.send(content: Data("data: news\n\n".utf8), completion: .contentProcessed { _ in }) }
        }
        timer.resume()
    }

    @MainActor
    func url() async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://127.0.0.1:\(try #require(listener.port).rawValue)/")!
    }

    /// How many events the page answered after `date`.
    func answered(after date: Date) -> Int {
        queue.sync { answers.filter { $0 > date }.count }
    }

    /// The longest the page went without answering an event, from `date`
    /// to now.
    func longestQuiet(since date: Date) -> TimeInterval {
        queue.sync {
            let times = [date] + answers.filter { $0 > date } + [Date()]
            return zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
        }
    }

    func stop() {
        queue.sync {
            timer.cancel()
            for stream in streams { stream.cancel() }
            listener.cancel()
        }
    }
}

/// Pages out of sight keep running, but in Low Power Mode (spec #118). A
/// browser with no window has every page out of sight. Low Power Mode is set
/// for each test's own store, so other tests' pages run on as they were;
/// these take turns all the same, each timing how its page runs.
@MainActor
@Suite(.serialized)
struct HiddenPagesTests {
    /// A suspended page answers nothing for this long, and more, where a
    /// running one answers ten events a second.
    private static let paused: TimeInterval = 3

    /// Whether WebKit has the page's process suspended, by its own account
    /// (`_webProcessState`, 3 for suspended): what a busy Mac doesn't
    /// change, where how long a running page goes without an answer it does.
    private func isSuspended(_ page: WKWebView) throws -> Bool {
        let state = try #require(page.value(forKey: "_webProcessState") as? Int, "WebKit no longer says how a page's process runs")
        return state == 3
    }

    /// What a page heard over the last `seconds`: how many events, and the
    /// longest it went without one, up to now. A running page hears each as
    /// it comes; a suspended one hears nothing until it is woken.
    private struct Heard { let events: Int; let longestWait: Double; let ticks: Int }

    private func heard(_ tab: Nerda.Tab, over seconds: Double) async throws -> Heard {
        let script = """
            const now = Date.now(), from = now - \(seconds * 1000);
            const times = [from, ...heard.filter(t => t > from), now];
            const waits = times.slice(1).map((t, i) => t - times[i]);
            return [times.length - 2, Math.max(...waits) / 1000, ticked.filter(t => t > from).length];
            """
        let values = try #require(try await tab.webView.callAsyncJavaScript(script, contentWorld: .page) as? [Double])
        return Heard(events: Int(values[0]), longestWait: values[1], ticks: Int(values[2]))
    }

    /// A tab out of sight on the server's page, with Low Power Mode off,
    /// and a page in sight elsewhere for as long as the test keeps it: what
    /// the tab answers reaches the server when it sends it, not as late as a
    /// busy Mac leaves the pages' network process with none (`PageInSight`).
    private func listeningTab(_ server: StreamServer) async throws -> (Browser, Nerda.Tab, PageInSight) {
        let inSight = try await PageInSight()
        let browser = browserRunningOutOfSight()
        return (browser, try await listeningTab(server, in: browser), inSight)
    }

    /// Another tab of `browser` out of sight on the server's page.
    private func listeningTab(_ server: StreamServer, in browser: Browser) async throws -> Nerda.Tab {
        let tab = browser.open(try await server.url())
        try await waitFor("Hearing") {
            guard !tab.webView.isLoading, let heard = try? await heard(tab, over: 1) else { return false }
            return heard.events > 0
        }
        return tab
    }

    /// Out of sight for longer than WebKit takes to suspend a page, the page
    /// still hears the events as they come: over six seconds it answers
    /// twenty or more, unasked, and WebKit never once has it suspended. A
    /// suspended page answers none until something wakes it, and nothing
    /// here does. Its own timers stay slowed, as WebKit slows a hidden
    /// page's: far fewer than ten ticks a second.
    @Test func aHiddenPageKeepsRunning() async throws {
        let server = try StreamServer()
        defer { server.stop() }
        let (browser, tab, inSight) = try await listeningTab(server)
        try await Task.sleep(for: .seconds(8))

        let since = Date()
        var suspended = false
        try await waitFor("Six seconds, and twenty events answered out of sight", timeout: .seconds(15)) {
            suspended = try suspended || isSuspended(tab.webView)
            return Date().timeIntervalSince(since) >= 6 && server.answered(after: since) >= 20
        }
        #expect(!suspended, "WebKit suspended the page out of sight")
        let over = Date().timeIntervalSince(since)
        let heard = try await heard(tab, over: over)
        #expect(Double(heard.ticks) < 10 * over / 2, "\(heard) over \(over) s")
        withExtendedLifetime((browser, inSight)) {}
    }

    /// Low Power Mode turned on suspends a page already out of sight, and
    /// turned off lets it run again, without the page being made anew.
    /// WebKit suspends it about a second after the mode comes on: the page
    /// then answers no event for seconds on end, where a running one answers
    /// ten a second, and WebKit says it is suspended. Turned off, it answers
    /// again, and isn't suspended again meanwhile.
    @Test func hiddenPagesFollowLowPowerMode() async throws {
        let server = try StreamServer()
        defer { server.stop() }
        let (browser, tab, inSight) = try await listeningTab(server)
        let page = tab.webView
        // A page just loaded runs a while longer whatever the mode.
        try await Task.sleep(for: .seconds(3))

        LowPowerMode.force(true, for: browser.dataStore)
        LowPowerMode.changed()
        let on = Date()
        try await waitFor("Paused", timeout: .seconds(10)) { server.longestQuiet(since: on) >= Self.paused }
        #expect(try isSuspended(page))

        LowPowerMode.force(false, for: browser.dataStore)
        LowPowerMode.changed()
        let off = Date()
        try await waitFor("Answering again") { server.answered(after: off) > 0 }
        // From its first answer: waking takes a moment of its own.
        let back = Date()
        var suspended = false
        try await waitFor("Twenty events answered again") {
            suspended = try suspended || isSuspended(page)
            return server.answered(after: back) >= 20
        }
        #expect(!suspended, "WebKit suspended the page again")
        #expect(tab.webView === page)
        withExtendedLifetime((browser, inSight)) {}
    }

    /// Low Power Mode reaches every page of a profile out of sight, not
    /// only its first: each process with a page of the profile's is told,
    /// so a page in a process of its own is suspended too, and runs again.
    @Test func lowPowerModeReachesEveryHiddenPageOfAProfile() async throws {
        let first = try StreamServer(), second = try StreamServer()
        defer { first.stop(); second.stop() }
        let (browser, tab, inSight) = try await listeningTab(first)
        let other = try await listeningTab(second, in: browser)
        let pids = (try #require(tab.pid), try #require(other.pid))
        try #require(pids.0 != pids.1, "the two pages share a process: the test can't tell")
        try await Task.sleep(for: .seconds(3))

        LowPowerMode.force(true, for: browser.dataStore)
        LowPowerMode.changed()
        let on = Date()
        try await waitFor("Both pages quiet", timeout: .seconds(10)) {
            first.longestQuiet(since: on) >= Self.paused && second.longestQuiet(since: on) >= Self.paused
        }

        LowPowerMode.force(false, for: browser.dataStore)
        LowPowerMode.changed()
        let off = Date()
        try await waitFor("Both pages answering again") {
            first.answered(after: off) >= 20 && second.answered(after: off) >= 20
        }
        withExtendedLifetime((browser, inSight)) {}
    }

    /// A page made as the mode changes, before Nerda hears of it (the Mac's
    /// notice comes a moment after), changes it for the pages of its
    /// profile already open too: they are suspended with it, not left
    /// running until the next change.
    @Test func aPageMadeAsTheModeChangesTakesTheOpenOnesWithIt() async throws {
        let server = try StreamServer()
        defer { server.stop() }
        let (browser, _, inSight) = try await listeningTab(server)
        try await Task.sleep(for: .seconds(3))

        LowPowerMode.force(true, for: browser.dataStore)
        browser.open(URL(string: "about:blank")!)
        LowPowerMode.changed()
        let on = Date()
        try await waitFor("Paused", timeout: .seconds(10)) { server.longestQuiet(since: on) >= Self.paused }
        LowPowerMode.force(false, for: browser.dataStore)
        LowPowerMode.changed()
        withExtendedLifetime((browser, inSight)) {}
    }

    /// Low Power Mode set for one data store, as a test sets it for its own,
    /// reaches that store's pages and no other's: one test turning it on
    /// leaves the pages of the tests beside it running as they were.
    @Test func lowPowerModeForOneStoreLeavesTheOthers() throws {
        let mine = Browser(dataStore: .nonPersistent()), other = Browser(dataStore: .nonPersistent())
        LowPowerMode.force(false, for: mine.dataStore)
        LowPowerMode.force(false, for: other.dataStore)
        defer {
            LowPowerMode.force(nil, for: mine.dataStore)
            LowPowerMode.force(nil, for: other.dataStore)
        }
        mine.open(URL(string: "about:blank")!)
        other.open(URL(string: "about:blank")!)
        let page = { (browser: Browser) in try #require(browser.tabs.last).webView }
        let (minePage, otherPage) = (try page(mine), try page(other))
        #expect(minePage.configuration.preferences.inactiveSchedulingPolicy == .none)

        LowPowerMode.force(true, for: mine.dataStore)
        LowPowerMode.changed()
        #expect(minePage.configuration.preferences.inactiveSchedulingPolicy == .suspend)
        #expect(otherPage.configuration.preferences.inactiveSchedulingPolicy == .none)
        LowPowerMode.force(false, for: mine.dataStore)
        LowPowerMode.changed()
        #expect(minePage.configuration.preferences.inactiveSchedulingPolicy == .none)
    }

    /// NERDA_HIDDEN_RUN=0 leaves a page made in that run as WebKit has it,
    /// suspended out of sight. The switch is read as each page is made, so
    /// it is set only around that, and the next page runs again.
    @Test func theSwitchLeavesWebKitsOwn() throws {
        defer { Speedups.overrides[.hiddenRun] = nil }
        let browser = Browser(dataStore: .nonPersistent())
        LowPowerMode.force(false, for: browser.dataStore)
        Speedups.overrides[.hiddenRun] = false
        browser.open(URL(string: "about:blank")!)
        let off = try #require(browser.tabs.last).webView.configuration.preferences.inactiveSchedulingPolicy
        Speedups.overrides[.hiddenRun] = nil
        #expect(off == WKPreferences().inactiveSchedulingPolicy)

        browser.open(URL(string: "about:blank")!)
        #expect(try #require(browser.tabs.last).webView.configuration.preferences.inactiveSchedulingPolicy == .none)
    }
}
