import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Waits up to two seconds for `done`.
@MainActor
private func until(_ done: () -> Bool) async throws {
    for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
}

private func saved(_ host: String, pinned: Bool = false) -> Session.Tab {
    Session.Tab(url: URL(string: "https://\(host)/")!, title: host, state: nil, zoom: 1,
                pinned: pinned ? true : nil, home: nil)
}

/// Restored in one go, the tabs come back as they did one by one: pinned
/// first, each kind in its own order, the one on screen by its place.
@MainActor
@Test func restoredTabsKeepTheirOrder() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    let tabs = [saved("a.test"), saved("p.test", pinned: true), saved("b.test"), saved("q.test", pinned: true)]
    try JSONEncoder().encode(Session(tabs: tabs, selected: 2)).write(to: file)

    let browser = Browser()
    browser.restore(from: file)
    #expect(browser.tabs.map(\.title) == ["p.test", "q.test", "a.test", "b.test"])
    #expect(browser.selectedID == browser.tabs[2].id)
    #expect(browser.tabs.allSatisfy { $0.delegate === browser })

    // More of them later go above the rest, as `add` puts them.
    browser.add([Nerda.Tab(restoring: saved("c.test")), Nerda.Tab(restoring: saved("r.test", pinned: true))])
    #expect(browser.tabs.map(\.title) == ["r.test", "p.test", "q.test", "c.test", "a.test", "b.test"])
}

/// The tab on screen is kept as the list changes, and what shows it hears
/// only of a change to it, not of every tab moved in the list.
@MainActor
@Test func theTabOnScreenIsKeptAsTheListChanges() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    try JSONEncoder().encode(Session(tabs: [saved("a.test"), saved("b.test"), saved("c.test")], selected: 1))
        .write(to: file)

    let browser = Browser()
    browser.restore(from: file)
    #expect(browser.selected?.title == "b.test")

    final class Flag: @unchecked Sendable { var raised = false }
    let told = Flag()
    withObservationTracking { _ = browser.selected } onChange: { told.raised = true }
    browser.move(browser.tabs[2].id, pinned: false, to: 0)
    #expect(!told.raised)
    #expect(browser.selected?.title == "b.test")

    browser.select(browser.tabs[0].id)
    #expect(told.raised)
    #expect(browser.selected === browser.tabs[0])

    let closed = browser.selected!
    browser.close(closed.id)
    #expect(browser.selected?.title == "b.test")
    #expect(browser.selected?.id == browser.selectedID)
    browser.reopenClosedTab()
    #expect(browser.selected?.title == closed.title)
    #expect(browser.selected !== closed)

    browser.closeAll()
    #expect(browser.selected == nil)
}

/// A secondary window closed is one entry in Recently Closed, which brings
/// back all its tabs with the one it showed on screen; one tab, a tab's entry.
@MainActor
@Test func aClosedWindowComesBackWithAllItsTabs() throws {
    let history = Session.Tab(url: nil, title: "History", state: nil, zoom: 1, pinned: nil, home: nil, history: true)
    let entry = try #require(Session.ClosedTab(window: Session(tabs: [saved("a.test"), history, saved("b.test")], selected: 2)))
    #expect(entry.tab == saved("b.test"))
    let window = try #require(entry.window)
    #expect(window.tabs == [saved("a.test"), saved("b.test")] && window.selected == 1)

    let one = try #require(Session.ClosedTab(window: Session(tabs: [history, saved("a.test")], selected: 0)))
    #expect(one.tab == saved("a.test") && one.window == nil)
    #expect(Session.ClosedTab(window: Session(tabs: [history], selected: 0)) == nil)

    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reopened = Browser(secondary: true)
    reopened.restore(window, from: folder.appending(path: "window.json"), loadingPins: true)
    #expect(reopened.tabs.map(\.title) == ["a.test", "b.test"])
    #expect(reopened.selected?.title == "b.test")
}

/// Saved off the main thread, the file is what it always was, and written
/// only when the tabs changed; a save that waits comes after one on its way.
@MainActor
@Test func theSessionIsWrittenInTheBackgroundOnlyWhenItChanged() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    let browser = Browser()
    browser.add([Nerda.Tab(restoring: saved("a.test")), Nerda.Tab(restoring: saved("b.test"))])
    browser.sessionFile = file

    browser.saveSession(waiting: false)
    browser.saveSession()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try Data(contentsOf: file) == (try encoder.encode(browser.session)))

    // Unchanged, nothing is written.
    try FileManager.default.removeItem(at: file)
    browser.saveSession(waiting: false)
    Session.writer.sync {}
    #expect(!FileManager.default.fileExists(atPath: file.path))

    browser.rename(browser.tabs[0].id, to: "Reading")
    browser.saveSession(waiting: false)
    Session.writer.sync {}
    #expect(try JSONDecoder().decode(Session.self, from: Data(contentsOf: file)).tabs.first?.name == "Reading")
}

/// A sleeping tab's picture is kept packed, and comes back as it was.
@MainActor
@Test func aSleepingTabKeepsItsPictureAsItWas() async throws {
    let size = NSSize(width: 52, height: 32)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill(using: .copy)
        return true
    }
    let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let packed = try #require(Nerda.Tab.png(pixels))
    let back = try #require(NSBitmapImageRep(data: packed))
    let original = NSBitmapImageRep(cgImage: pixels)
    #expect(back.pixelsWide == original.pixelsWide && back.pixelsHigh == original.pixelsHigh)
    for (x, y) in [(0, 0), (original.pixelsWide - 1, 0), (0, original.pixelsHigh - 1)] {
        // The same to the last of 255 steps: only the colour profile's rounding differs.
        let colors = [back, original].compactMap { $0.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        let channels = colors.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] }
        #expect(channels.count == 2 && zip(channels[0], channels[1]).allSatisfy { abs($0 - $1) < 1 / 255 })
    }

    let tab = Nerda.Tab(url: URL(string: "about:blank")!)
    tab.sleep(keeping: image)
    try await until { tab.look != nil }
    #expect(tab.look.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width } == pixels.width)
    _ = tab.webView
    #expect(tab.look == nil)
}

/// What had the keyboard, taken out of the page and put back, has it
/// again; what was let go of first doesn't.
@MainActor
@Test func anElementMovedInThePageKeepsTheKeyboard() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(Nerda.Tab.keepFocus)
    let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    page.loadHTMLString("<input id=field><div id=elsewhere></div>", baseURL: nil)
    try await until { !page.isLoading && page.url != nil }
    try await Task.sleep(for: .milliseconds(100))

    let move = """
        const field = document.getElementById('field');
        field.remove();
        await new Promise(done => setTimeout(done, 0));
        document.getElementById('elsewhere').append(field);
        await new Promise(done => setTimeout(done, 0));
        return document.activeElement === field;
        """
    _ = try await page.callAsyncJavaScript("document.getElementById('field').focus()", contentWorld: .page)
    #expect(try await page.callAsyncJavaScript(move, contentWorld: .page) as? Bool == true)

    _ = try await page.callAsyncJavaScript("document.getElementById('field').blur()", contentWorld: .page)
    #expect(try await page.callAsyncJavaScript(move, contentWorld: .page) as? Bool == false)
}

/// A page out of sight that asks something waits for its tab to come on
/// screen, and is answered then, not before.
@MainActor
@Test func aHiddenTabsQuestionWaitsForItsTab() async throws {
    let browser = Browser()
    browser.open(URL(string: "about:blank")!)
    let asking = browser.open(URL(string: "data:text/html,<title>waiting</title>")!, inBackground: true)
    try await until { asking.title == "waiting" }
    _ = try await asking.webView.evaluateJavaScript("setTimeout(() => { confirm('Leave?'); document.title = 'answered'; })")
    try await Task.sleep(for: .milliseconds(300))
    #expect(asking.title == "waiting")

    // With no window to show it in, the question is let go once its tab is on screen.
    browser.select(asking.id)
    try await until { asking.title == "answered" }
    #expect(asking.title == "answered")
}

/// A page opened from a file keeps what it loads from the folders around
/// it when its tab wakes from sleep and when it is reloaded: WebKit lets
/// the page read them on each load, its saved history's included, where
/// read access asked for its own folder alone would leave out `../`.
@MainActor
@Test func aFilesPageKeepsWhatIsAroundItWhenWokenOrReloaded() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "page")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "index.html")
    try Data("<script src=../shared.js></script>".utf8).write(to: file)
    try Data("window.shared = true".utf8).write(to: root.appending(path: "shared.js"))

    let tab = Nerda.Tab(url: file)
    func sharedRan() async throws -> Bool {
        let page = tab.webView
        try await until { !page.isLoading && page.url == file }
        return try await page.callAsyncJavaScript("return window.shared === true", contentWorld: .page) as? Bool == true
    }
    #expect(try await sharedRan())
    tab.sleep()
    #expect(try await sharedRan())
    tab.reload()
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await sharedRan())
}

/// Stands in for WebKit's own Open Link in New Window, counting the times it is asked.
private final class LinkOpener: NSObject {
    var opened = 0
    @objc func open(_ sender: Any?) { opened += 1 }
}

/// A link's right-click menu says Open Link in New Tab, which leaves the
/// tab behind, as in Safari; ⌥ shows one that goes to it. Both open where
/// the site's pop-ups are blocked: the pick itself is the click.
@MainActor
@Test func openLinkInNewTabStaysBehindUnlessOptionIsHeld() throws {
    _ = NSApplication.shared
    let page = SwipingWebView(frame: .zero, configuration: WKWebViewConfiguration())
    let opener = LinkOpener()
    let menu = NSMenu()
    let item = NSMenuItem(title: "Open Link in New Window", action: #selector(LinkOpener.open(_:)), keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    item.target = opener
    menu.addItem(item)
    menu.addItem(withTitle: "Copy Link", action: nil, keyEquivalent: "")
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    page.willOpenMenu(menu, with: event)

    // Screenshot's items may follow, with that setting on.
    #expect(menu.items.prefix(4).map(\.title) == ["Open Link in New Tab", "Open Link in New Tab and Go to It",
                                        "Open Link in Incognito Window", "Copy Link"])
    #expect(menu.items[1].isAlternate && menu.items[1].keyEquivalentModifierMask == .option)

    menu.performActionForItem(at: 0)
    #expect(opener.opened == 1)
    #expect(page.takeLinkAsk() == .behind)
    // Used up: the page's own next window is an ordinary one.
    #expect(page.takeLinkAsk() == nil)

    menu.performActionForItem(at: 1)
    #expect(opener.opened == 2)
    #expect(page.takeLinkAsk() == .front)

    menu.performActionForItem(at: 2)
    #expect(opener.opened == 3)
    #expect(page.takeLinkAsk() == .incognito)
}

/// A window WebKit says no click or key asked for, as it may say of a link
/// picked from the right-click menu.
private final class UnclickedAction: WKNavigationAction {
    let url: URL
    init(_ url: URL) { self.url = url }
    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { .other }
    @objc(_isUserInitiated) var userInitiated: Bool { false }
}

/// Open Link in New Tab and Go to It opens its tab in front even where the
/// site's pop-ups are blocked, whatever WebKit says of the click; a window
/// the page asks for by itself is still kept back.
@MainActor
@Test func goToItFromTheMenuIsNoPopup() throws {
    _ = NSApplication.shared
    let browser = Browser(dataStore: .nonPersistent())
    let tab = Tab()
    browser.add(tab)
    let page = try #require(tab.webView as? SwipingWebView)
    let link = URL(string: "https://example.com/next")!
    func open() -> WKWebView? {
        browser.webView(page, createWebViewWith: WKWebViewConfiguration(), for: UnclickedAction(link),
                        windowFeatures: WKWindowFeatures())
    }
    #expect(open() == nil)
    #expect(tab.blockedPopups == [link])

    let opener = LinkOpener()
    let menu = NSMenu()
    let item = NSMenuItem(title: "Open Link in New Window", action: #selector(LinkOpener.open(_:)), keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    item.target = opener
    menu.addItem(item)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    page.willOpenMenu(menu, with: event)
    menu.performActionForItem(at: 1)
    let opened = try #require(open())
    #expect(browser.tabs.count == 2)
    #expect(browser.selected?.webView === opened)
    browser.closeAll()
}

/// With Load background tabs when shown, a link opened behind keeps its
/// address and makes no page until it is shown; saved, it stays unloaded.
@MainActor
@Test func aBackgroundTabWaitsUntilShown() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "page.html")
    try Data("<title>Arrived</title>".utf8).write(to: file)

    let browser = Browser()
    browser.open(URL(string: "about:blank")!)
    let front = browser.selectedID
    let site = browser.openBehind(URL(string: "https://www.example.test/a")!, waiting: true)
    let waiting = browser.openBehind(file, waiting: true)
    #expect(browser.selectedID == front)
    #expect(site.page == nil && site.isAsleep && site.hasPage)
    #expect(site.title == "example.test")
    #expect(waiting.page == nil)
    let saved = try #require(browser.session.tabs.first { $0.url == file })
    #expect(saved.state == nil)

    browser.select(waiting.id)
    // On screen, PageView asks for the page, which wakes it to its address.
    let page = waiting.webView
    try await until { waiting.title == "Arrived" }
    #expect(page.url == file)
    #expect(site.page == nil)
}

/// Moved to another window, a tab takes its page along, still awake; a
/// pinned site stays behind, asleep, and only its page goes, as a tab of
/// the list. A secondary window keeps no pinned sites or bookmarks.
@MainActor
@Test func aTabMovesToAnotherWindowWithItsPage() throws {
    let browser = Browser()
    browser.add([Nerda.Tab(restoring: saved("pin.test", pinned: true))])
    let tab = browser.open(URL(string: "about:blank")!)
    let page = tab.webView
    let moved = Browser(secondary: true)

    browser.move(tab.id, to: moved)
    #expect(!browser.tabs.contains { $0 === tab })
    #expect(moved.tabs.map(\.id) == [tab.id] && moved.selectedID == tab.id)
    #expect(tab.page === page && tab.delegate === moved)
    // The pinned site alone was left: a new tab goes on screen, not the site.
    #expect(browser.selected?.isBlank == true)

    let pin = browser.tabs[0]
    browser.move(pin.id, to: moved)
    #expect(browser.tabs[0].isPinned && browser.tabs[0].site == URL(string: "https://pin.test/") && browser.tabs[0] !== pin)
    #expect(moved.tabs.contains { $0 === pin } && !pin.isPinned && pin.home == nil)

    // Let go in another window's gap: in its place there.
    let third = browser.open(URL(string: "about:blank")!)
    browser.move(third.id, to: moved, at: 1)
    #expect(moved.tabs.filter(Browser.listed).firstIndex { $0 === third } == 1)

    moved.setPinned(true, tab.id)
    moved.bookmark(tab.id)
    #expect(!tab.isPinned && tab.bookmark == nil)
    // An incognito window's tab can't go to a window that keeps cookies.
    let incognito = Browser(dataStore: .nonPersistent())
    moved.move(tab.id, to: incognito)
    #expect(moved.tabs.contains { $0 === tab })
    browser.closeAll()
    moved.closeAll()
}
