import AppKit
import Network
import Testing
import WebKit
@testable import Nerda

/// Serves `/a`, a page that answers, and `/loop`, one whose script goes round
/// a loop it never leaves a moment after it loads.
@MainActor
private final class HangServer {
    let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = path == "/loop"
                    ? "<title>Loop</title><script>setTimeout(() => { while (true) {} }, 200)</script>"
                    : "<title>\(path.dropFirst())</title>"
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String) async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://127.0.0.1:\(try #require(listener.port).rawValue)\(path)")!
    }
}

/// A browser with one tab whose page has stopped answering, shown in a window
/// kept out of sight, where a key pressed in it reaches its process as the
/// owner's would.
@MainActor
private final class HungTab {
    let server: HangServer
    /// Its page loads out of sight, before the window has it.
    let browser = browserRunningOutOfSight()
    let tab = Nerda.Tab()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    /// Every page process the tab had, ended at the close so no loop outlives the test.
    var pids: Set<pid_t> = []

    init(server: HangServer, after paths: [String] = [], askAfter: TimeInterval? = nil) async throws {
        self.server = server
        if let askAfter { browser.hangWaits.askAfter = askAfter }
        // Quick to give up on a page, this browser only: other tests' pages,
        // slow to answer on a busy Mac, keep Nerda's patience.
        browser.hangWaits.patience = 0.5
        window.isReleasedWhenClosed = false
        browser.add(tab)
        browser.select(tab.id)
        for path in paths + ["/loop"] {
            tab.go(to: try await server.url(path))
            try await waitFor { tab.page?.url?.path == path && tab.page?.isLoading == false }
        }
        window.contentView = tab.webView
        window.orderBack(nil)
        pids.insert(try #require(tab.pid))
        // The loop under way, then a key the page never takes.
        try await Task.sleep(for: .milliseconds(400))
        press()
    }

    func press() {
        guard let page = tab.page else { return }
        page.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "a",
                                            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
    }

    func close() {
        if let pid = tab.pid { pids.insert(pid) }
        for pid in pids { kill(pid, SIGKILL) }
        window.contentView = nil
        window.close()
    }
}

@Suite(.serialized)
@MainActor
struct HungPagesTests {
    @Test func aPageInAnEndlessLoopIsReportedAsNotAnswering() async throws {
        let hung = try await HungTab(server: HangServer())
        defer { hung.close() }
        #expect(!hung.tab.isHung)
        // WebKit's word comes three seconds after the key, then two pings go unanswered.
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
    }

    @Test func aPageBusyForAMomentIsNotTakenForHung() async throws {
        let server = try HangServer()
        let browser = Browser(dataStore: .nonPersistent())
        let tab = Nerda.Tab()
        browser.add(tab)
        tab.go(to: try await server.url("/a"))
        try await waitFor { tab.page?.isLoading == false }
        let page = try #require(tab.page)
        // As WebKit says three seconds after a key the page was too busy to take.
        page.evaluateJavaScript("setTimeout(() => { const end = Date.now() + 1500; while (Date.now() < end) {} })", completionHandler: nil)
        browser.webProcessDidBecomeUnresponsive(page)
        try await Task.sleep(for: .seconds(4.5))
        #expect(!tab.isHung)
        #expect(!tab.asksAboutHang)
    }

    @Test func theOwnerReachingForAHungPageIsAskedToWaitOrReload() async throws {
        let hung = try await HungTab(server: HangServer(), askAfter: 0.5)
        defer { hung.close() }
        #expect(!hung.tab.asksAboutHang)
        try await waitFor(timeout: .seconds(15)) { hung.tab.asksAboutHang }
        // Wait: the card goes, and the page is left as it is.
        hung.tab.waitForHang()
        #expect(!hung.tab.asksAboutHang)
        #expect(hung.tab.isHung)
    }

    /// Whether the tab's page answers, in a second.
    private func answers(_ tab: Nerda.Tab) async -> Bool {
        guard let page = tab.page else { return false }
        return await withCheckedContinuation { done in
            var once = false
            page.evaluateJavaScript("1", in: nil, in: .defaultClient) { result in
                if !once { once = true; done.resume(returning: (try? result.get()) as? Int == 1) }
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !once { once = true; done.resume(returning: false) }
            }
        }
    }

    @Test func reloadingAHungPageGivesAFreshWorkingPageAtOnce() async throws {
        let hung = try await HungTab(server: HangServer())
        defer { hung.close() }
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
        let old = try #require(hung.tab.pid)
        hung.tab.reload()
        #expect(hung.tab.pid != old)
        #expect(!hung.tab.isHung)
        try await waitFor { await answers(hung.tab) }
        #expect(hung.tab.page?.url?.path == "/loop")
        try await waitFor("The hung process ended") { Processes.started(old) == nil }
    }

    @Test func typingAnAddressLeavesAHungPageAtOnce() async throws {
        let hung = try await HungTab(server: HangServer())
        defer { hung.close() }
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
        let old = try #require(hung.tab.pid)
        hung.tab.go(to: try await hung.server.url("/b"))
        try await waitFor { hung.tab.page?.title == "b" }
        #expect(await answers(hung.tab))
        try await waitFor("The hung process ended") { Processes.started(old) == nil }
    }

    @Test func goingBackFromAHungPageWorksAtOnce() async throws {
        let hung = try await HungTab(server: HangServer(), after: ["/a"])
        defer { hung.close() }
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
        let old = try #require(hung.tab.pid)
        hung.tab.goBack()
        try await waitFor { hung.tab.page?.title == "a" }
        #expect(await answers(hung.tab))
        #expect(hung.tab.canGoForward)
        try await waitFor("The hung process ended") { Processes.started(old) == nil }
    }

    /// A mouse's Back button goes the same way out as Back in the menu.
    @Test func theMouseBackButtonLeavesAHungPageAtOnce() async throws {
        let hung = try await HungTab(server: HangServer(), after: ["/a"])
        defer { hung.close() }
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
        let old = try #require(hung.tab.pid)
        let page = try #require(hung.tab.page)
        let click = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                            mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: CGMouseButton(rawValue: 3)!)
        page.otherMouseDown(with: try #require(click.flatMap(NSEvent.init(cgEvent:))))
        try await waitFor { hung.tab.page?.title == "a" }
        #expect(await answers(hung.tab))
        try await waitFor("The hung process ended") { Processes.started(old) == nil }
    }

    /// WebKit's word alone is no hang: a page that still answers keeps its
    /// process, and its changes are still asked about before they go.
    @Test func aPageWebKitThinksBusyStillAsksBeforeItsChangesGo() async throws {
        let server = try HangServer()
        let browser = Browser(dataStore: .nonPersistent())
        let tab = Nerda.Tab()
        browser.add(tab)
        tab.go(to: try await server.url("/a"))
        try await waitFor { tab.page?.isLoading == false }
        let page = try #require(tab.page)
        let pid = try #require(tab.pid)
        tab.hasUnsavedWork = true
        browser.webProcessDidBecomeUnresponsive(page)
        // With no window to ask in, the question is answered Stay.
        browser.close(tab.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.tabs.contains { $0 === tab })
        tab.go(to: try await server.url("/b"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.page === page)
        #expect(tab.pid == pid)
        #expect(tab.hasUnsavedWork)
        #expect(page.url?.path == "/a")
    }

    @Test func puttingAHungPageToSleepEndsItsProcess() async throws {
        let hung = try await HungTab(server: HangServer())
        defer { hung.close() }
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
        let old = try #require(hung.tab.pid)
        hung.tab.sleep()
        #expect(hung.tab.isAsleep)
        try await waitFor("The hung process ended") { Processes.started(old) == nil }
        // Shown again, it wakes in a page that works.
        _ = hung.tab.webView
        try await waitFor { await answers(hung.tab) }
    }

    @Test func closingAHungTabEndsItsProcess() async throws {
        let hung = try await HungTab(server: HangServer())
        defer { hung.close() }
        hung.browser.add(Nerda.Tab(), inBackground: true)
        try await waitFor(timeout: .seconds(15)) { hung.tab.isHung }
        let old = try #require(hung.tab.pid)
        hung.browser.close(hung.tab.id)
        #expect(!hung.browser.tabs.contains { $0 === hung.tab })
        try await waitFor("The hung process ended") { Processes.started(old) == nil }
    }

    /// A tab on screen and one out of sight at `path`, its page loaded.
    private func hiddenTab(_ path: String, on server: HangServer) async throws -> (Browser, Nerda.Tab) {
        // A hidden page spins, or works, as it would with the Mac's Low
        // Power Mode off: on, it would be suspended.
        let browser = browserRunningOutOfSight()
        browser.hangWaits.patience = 0.5
        let shown = Nerda.Tab()
        browser.add(shown)
        shown.go(to: try await server.url("/a"))
        let hidden = Nerda.Tab()
        browser.add(hidden, inBackground: true)
        hidden.go(to: try await server.url(path))
        try await waitFor { hidden.page?.url?.path == path && hidden.page?.isLoading == false }
        #expect(browser.selectedID == shown.id)
        return (browser, hidden)
    }

    @Test func aHiddenPageSpinningInALoopIsEndedAndPutToSleep() async throws {
        let (browser, tab) = try await hiddenTab("/loop", on: HangServer())
        let old = try #require(tab.pid)
        defer { kill(old, SIGKILL) }
        try await Task.sleep(for: .milliseconds(400))
        // Two looks a second apart, as the minute's look sees a whole core taken.
        browser.lookForSpinningPages()
        try await Task.sleep(for: .seconds(1))
        browser.lookForSpinningPages()
        try await waitFor { tab.isAsleep }
        try await waitFor("The spinning process ended") { Processes.started(old) == nil }
        #expect(browser.tabs.contains { $0 === tab })
    }

    @Test func aHiddenPageWorkingOnPurposeIsLeftRunning() async throws {
        let (browser, tab) = try await hiddenTab("/a", on: HangServer())
        let pid = try #require(tab.pid)
        defer { kill(pid, SIGKILL) }
        // A core kept busy by a worker, its page free to answer.
        tab.page?.evaluateJavaScript("""
            new Worker(URL.createObjectURL(new Blob(['while (true) {}'])))
            """, completionHandler: nil)
        try await Task.sleep(for: .milliseconds(400))
        browser.lookForSpinningPages()
        try await Task.sleep(for: .seconds(1))
        browser.lookForSpinningPages()
        try await Task.sleep(for: .seconds(1.5))
        #expect(!tab.isAsleep)
        #expect(tab.pid == pid)
    }

    @Test func turningHangHandlingOffLeavesAHungPageAsWebKitDoes() async throws {
        Speedups.overrides[.hangHandling] = false
        defer { Speedups.overrides[.hangHandling] = nil }
        let hung = try await HungTab(server: HangServer())
        defer { hung.close() }
        let pid = try #require(hung.tab.pid)
        // WebKit's word three seconds after the key, and time for two pings.
        try await Task.sleep(for: .seconds(5))
        #expect(!hung.tab.isHung)
        hung.tab.reload()
        #expect(hung.tab.pid == pid)
    }
}
