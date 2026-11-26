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

    /// A tab out of sight on the server's page, with Low Power Mode off.
    private func listeningTab(_ server: StreamServer) async throws -> (Browser, Nerda.Tab) {
        let browser = Browser(dataStore: .nonPersistent())
        LowPowerMode.force(false, for: browser.dataStore)
        browser.open(try await server.url())
        let tab = try #require(browser.tabs.last)
        try await waitFor("Hearing") {
            guard !tab.webView.isLoading, let heard = try? await heard(tab, over: 1) else { return false }
            return heard.events > 0
        }
        return (browser, tab)
    }

    /// Out of sight for longer than WebKit takes to suspend a page, the page
    /// still hears the events as they come: it answers twenty more, unasked.
    /// A suspended page answers none until something wakes it, and nothing
    /// here does. Its own timers stay slowed, as WebKit slows a hidden
    /// page's: far fewer than ten ticks a second.
    @Test func aHiddenPageKeepsRunning() async throws {
        let server = try StreamServer()
        defer { server.stop() }
        let (browser, tab) = try await listeningTab(server)
        try await Task.sleep(for: .seconds(8))

        let since = Date()
        try await waitFor("Twenty events answered out of sight") { server.answered(after: since) >= 20 }
        let over = Date().timeIntervalSince(since)
        let heard = try await heard(tab, over: over)
        #expect(Double(heard.ticks) < 10 * over / 2, "\(heard) over \(over) s")
        withExtendedLifetime(browser) {}
    }

    /// Low Power Mode turned on suspends a page already out of sight, and
    /// turned off lets it run again, without the page being made anew.
    /// WebKit suspends it about a second after the mode comes on: the page
    /// then answers no event for seconds on end, where a running one answers
    /// ten a second. Turned off, it answers again.
    @Test func hiddenPagesFollowLowPowerMode() async throws {
        let server = try StreamServer()
        defer { server.stop() }
        let (browser, tab) = try await listeningTab(server)
        let page = tab.webView
        // A page just loaded runs a while longer whatever the mode.
        try await Task.sleep(for: .seconds(3))

        LowPowerMode.force(true, for: browser.dataStore)
        LowPowerMode.changed()
        let on = Date()
        try await waitFor("Three seconds without an answer", timeout: .seconds(10)) { server.longestQuiet(since: on) >= 3 }

        LowPowerMode.force(false, for: browser.dataStore)
        LowPowerMode.changed()
        let off = Date()
        try await waitFor("Twenty events answered again") { server.answered(after: off) >= 20 }
        #expect(tab.webView === page)
        withExtendedLifetime(browser) {}
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
