import Foundation
import Network
import Testing
import WebKit
@testable import Nerda

/// Serves a page that hears a stream of events, ten a second, as a chat or
/// a dashboard hears its server, and keeps the time of each one heard and
/// each tick of its own 100 ms timer. On a queue of its own, so a busy main
/// thread in other tests never holds the stream up.
private final class StreamServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "HiddenPagesTests.stream")
    private let timer: DispatchSourceTimer
    /// Only on `queue`.
    private var streams: [NWConnection] = []

    static let page = """
        <script>
        window.heard = []; window.ticked = [];
        new EventSource('/events').onmessage = () => heard.push(Date.now());
        setInterval(() => ticked.push(Date.now()), 100);
        </script>
        """

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        timer = DispatchSource.makeTimerSource(queue: queue)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                if request.hasPrefix("GET /events") {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                    streams.append(connection)
                } else {
                    let body = Data(Self.page.utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [unowned self] in
            for stream in streams { stream.send(content: Data("data: news\n\n".utf8), completion: .contentProcessed { _ in }) }
        }
        timer.resume()
    }

    @MainActor
    func url() async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://127.0.0.1:\(try #require(listener.port).rawValue)/")!
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
/// browser with no window has every page out of sight. Low Power Mode is one
/// switch for the whole app, so these take turns.
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
        LowPowerMode.forced = false
        LowPowerMode.changed()
        let browser = Browser(dataStore: .nonPersistent())
        browser.open(try await server.url())
        let tab = try #require(browser.tabs.last)
        try await waitFor("Hearing") {
            guard !tab.webView.isLoading, let heard = try? await heard(tab, over: 1) else { return false }
            return heard.events > 0
        }
        return (browser, tab)
    }

    /// Out of sight for longer than WebKit takes to suspend a page, the page
    /// still hears each event as it comes. Its own timers stay slowed, as
    /// WebKit slows a hidden page's: far fewer than ten ticks a second.
    @Test func aHiddenPageKeepsRunning() async throws {
        let server = try StreamServer()
        defer { server.stop(); LowPowerMode.forced = nil; LowPowerMode.changed() }
        let (browser, tab) = try await listeningTab(server)
        try await Task.sleep(for: .seconds(8))

        let heard = try await heard(tab, over: 6)
        #expect(heard.longestWait < 1.5)
        #expect(heard.events >= 20)
        #expect(heard.ticks < 30)
        withExtendedLifetime(browser) {}
    }

    /// Low Power Mode turned on suspends a page already out of sight, and
    /// turned off lets it run again, without the page being made anew.
    /// WebKit suspends it about a second after the mode comes on, and the
    /// page hears what came meanwhile only once it runs again. The mode is
    /// on for as short a time as shows that, as other tests' spare pages
    /// go while it is.
    @Test func hiddenPagesFollowLowPowerMode() async throws {
        let server = try StreamServer()
        defer { server.stop(); LowPowerMode.forced = nil; LowPowerMode.changed() }
        let (browser, tab) = try await listeningTab(server)
        let page = tab.webView
        // A page just loaded runs a while longer whatever the mode.
        try await Task.sleep(for: .seconds(3))

        LowPowerMode.forced = true
        LowPowerMode.changed()
        try await Task.sleep(for: .seconds(4))
        LowPowerMode.forced = false
        LowPowerMode.changed()
        let suspended = try await heard(tab, over: 5)
        #expect(suspended.longestWait >= 2)

        try await Task.sleep(for: .seconds(6))
        let running = try await heard(tab, over: 5)
        #expect(running.longestWait < 1.5)
        #expect(tab.webView === page)
        withExtendedLifetime(browser) {}
    }

    /// NERDA_HIDDEN_RUN=0 leaves a page made in that run as WebKit has it,
    /// suspended out of sight. The switch is read as each page is made, so
    /// it is set only around that, and the next page runs again.
    @Test func theSwitchLeavesWebKitsOwn() throws {
        defer { Speedups.overrides[.hiddenRun] = nil; LowPowerMode.forced = nil }
        LowPowerMode.forced = false
        let browser = Browser(dataStore: .nonPersistent())
        Speedups.overrides[.hiddenRun] = false
        browser.open(URL(string: "about:blank")!)
        let off = try #require(browser.tabs.last).webView.configuration.preferences.inactiveSchedulingPolicy
        Speedups.overrides[.hiddenRun] = nil
        #expect(off == WKPreferences().inactiveSchedulingPolicy)

        browser.open(URL(string: "about:blank")!)
        #expect(try #require(browser.tabs.last).webView.configuration.preferences.inactiveSchedulingPolicy == .none)
    }
}
