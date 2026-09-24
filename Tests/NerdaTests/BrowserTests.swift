import Foundation
import Testing
import WebKit
@testable import Nerda

private let somewhere = URL(string: "https://example.com")!

@MainActor
@Test func closingTabsHandsTheScreenOn() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    browser.open(somewhere)
    let (top, middle, bottom) = (browser.tabs[0].id, browser.tabs[1].id, browser.tabs[2].id)

    // A tab that isn't showing goes without moving the selection.
    browser.selectedID = middle
    browser.close(top)
    #expect(browser.selectedID == middle)

    // The one showing hands over to the one sliding into its place…
    browser.close(middle)
    #expect(browser.selectedID == bottom)

    // …and the last one leaves nothing selected, and asks where to go next.
    browser.commandBarOpen = false
    browser.close(bottom)
    #expect(browser.tabs.isEmpty)
    #expect(browser.selectedID == nil)
    #expect(browser.commandBarOpen)
}

/// A closed tab takes its page with it: nothing else may keep it alive.
@MainActor
@Test func closedTabsAreFreed() {
    let browser = Browser()
    weak var tab: Tab?
    weak var page: WKWebView?
    // As the app's run loop does after every event: WebKit hands things out autoreleased.
    autoreleasepool {
        browser.open(somewhere)
        tab = browser.tabs[0]
        page = browser.tabs[0].webView
        browser.close(browser.tabs[0].id)
    }
    #expect(tab == nil)
    #expect(page == nil)
}

@MainActor
@Test func aTabIsNamedForItsSiteUntilThePageSaysOtherwise() {
    #expect(Tab(url: URL(string: "https://www.github.com/apple")!).title == "github.com")
    #expect(Tab(url: URL(string: "file:///tmp/notes.html")!).title == "file:///tmp/notes.html")
    #expect(Tab().title == "Untitled")
    #expect(Tab(url: URL(string: "http://localhost:3000/app")!).title == "localhost:3000")

    let tab = Tab(url: URL(string: "https://news.ycombinator.com")!)
    tab.failure = (URL(string: "https://gogle.cmo")!, "Not found")
    #expect(tab.title == "gogle.cmo")
}

/// A popup, or a link opened in a new tab, hands back to the page that opened it.
@MainActor
@Test func closingAPopupGoesBackToItsOpener() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    let opener = browser.tabs[1]
    let popup = browser.webView(opener.webView, createWebViewWith: WKWebViewConfiguration(),
                                for: WKNavigationAction(), windowFeatures: WKWindowFeatures())
    #expect(browser.selected?.webView === popup)

    browser.close(browser.selectedID!)
    #expect(browser.selectedID == opener.id)
}

@MainActor
@Test func closingTheBottomTabSelectsTheOneAbove() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    let (top, bottom) = (browser.tabs[0].id, browser.tabs[1].id)
    browser.selectedID = bottom
    browser.close(bottom)
    #expect(browser.selectedID == top)
}

@MainActor
@Test func openingATabPutsItFirstAndShowsIt() {
    let browser = Browser()
    #expect(browser.tabs.isEmpty)
    browser.open(URL(string: "https://www.google.com/")!)
    #expect(browser.tabs.first?.title == "google.com")
    #expect(browser.selectedID == browser.tabs.first?.id)
}

@Test(arguments: [
    ("google.com", "https://google.com"),
    ("  github.com/apple/swift ", "https://github.com/apple/swift"),
    ("http://example.com", "http://example.com"),
    ("localhost:3000", "http://localhost:3000"),
    ("192.168.1.1", "https://192.168.1.1"),
    ("ob-havo toshkent", "https://www.google.com/search?q=ob-havo%20toshkent"),
    ("swift", "https://www.google.com/search?q=swift"),
])
func typedTextBecomesAnAddress(input: String, expected: String) {
    #expect(Address.url(from: input)?.absoluteString == expected)
}

@Test func nothingTypedGoesNowhere() {
    #expect(Address.url(from: "   ") == nil)
}

@Test(arguments: [
    ("https://www.google.com/search?q=swift", "https://www.google.com"),
    ("http://localhost:3000/app", "http://localhost:3000"),
    ("http://192.168.1.1", "http://192.168.1.1"),
    ("file:///tmp/notes.html", nil),
    ("about:blank", nil),
] as [(String, String?)])
func iconsAreKeptPerOrigin(url: String, origin: String?) {
    #expect(Favicons.origin(of: URL(string: url)) == origin)
}

@Test func downloadsNeverOverwriteOrLeaveTheFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(Downloads.destination(for: "report.pdf", in: folder).lastPathComponent == "report.pdf")
    FileManager.default.createFile(atPath: folder.appending(path: "report.pdf").path, contents: nil)
    FileManager.default.createFile(atPath: folder.appending(path: "report (1).pdf").path, contents: nil)
    #expect(Downloads.destination(for: "report.pdf", in: folder).lastPathComponent == "report (2).pdf")

    FileManager.default.createFile(atPath: folder.appending(path: "README").path, contents: nil)
    #expect(Downloads.destination(for: "README", in: folder).lastPathComponent == "README (1)")

    #expect(Downloads.destination(for: "../../etc/passwd", in: folder) == folder.appending(path: "passwd"))
    #expect(Downloads.destination(for: "", in: folder).lastPathComponent == "download")
}

/// A sleeping tab lets its page go, keeps what the sidebar shows, and wakes
/// with a page again as soon as it is shown.
@MainActor
@Test func aSleepingTabWakesWhenShown() {
    let browser = Browser()
    browser.open(URL(string: "https://github.com")!)
    browser.open(somewhere)
    let tab = browser.tabs[1]

    tab.sleep()
    #expect(tab.isAsleep)
    #expect(tab.title == "github.com")

    browser.selectedID = tab.id
    _ = browser.selected?.webView
    #expect(!tab.isAsleep)
}

/// The tab on screen never sleeps, however long it has been there.
@MainActor
@Test func theTabOnScreenStaysAwake() {
    let browser = Browser()
    browser.open(somewhere)
    browser.sleepIdleTabs(unseenFor: 0)
    #expect(browser.tabs[0].isAsleep == false)
}

@MainActor
@Test func tabsAreReachedByNumberAndInTurn() {
    let browser = Browser()
    for _ in 1...4 { browser.open(somewhere) }
    let ids = browser.tabs.map(\.id)

    browser.selectTab(number: 2)
    #expect(browser.selectedID == ids[1])
    browser.selectTab(number: 9)  // always the last
    #expect(browser.selectedID == ids[3])
    browser.selectTab(number: 7)  // no seventh: stays put
    #expect(browser.selectedID == ids[3])

    browser.selectTab(after: 1)  // round from the end to the start
    #expect(browser.selectedID == ids[0])
    browser.selectTab(after: -1)
    #expect(browser.selectedID == ids[3])
}

@MainActor
@Test func closingTheWindowClosesItsTabs() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    browser.commandBarOpen = false
    browser.closeAll()
    #expect(browser.tabs.isEmpty)
    #expect(browser.selectedID == nil)
    #expect(browser.commandBarOpen)
}

/// Full screen stays in the page: the element fills it from inside a box
/// that would trap anything fixed (a transform), and goes back as it was,
/// with the page where it was, though it scrolled behind in the meantime.
@MainActor
@Test func anElementGoesFullScreenInsideThePageAndBack() async throws {
    let page = Tab().webView
    page.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let html = #"<div style="height: 3000px"></div><div style="transform: scale(1)"><div id="box" style="width: 20px">x</div></div><div style="height: 3000px"></div>"#
    page.loadHTMLString(html, baseURL: somewhere)
    while page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    func run(_ script: String) async throws -> Any? { try await page.callAsyncJavaScript(script, contentWorld: .page) }

    let fills = "const r = box.getBoundingClientRect(); return r.width === innerWidth && r.height === innerHeight"
    _ = try await run("scrollTo(0, 2800); await box.requestFullscreen()")
    #expect(try await run("return document.fullscreenElement === box") as? Bool == true)
    #expect(try await run(fills) as? Bool == true)

    _ = try await run("scrollTo(0, 4000); await document.exitFullscreen()")
    #expect(try await run("return document.fullscreenElement === null") as? Bool == true)
    #expect(try await run(fills) as? Bool == false)
    #expect(try await run("return scrollY") as? Int == 2800)
}

// MARK: - Session

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Waits for the tab's page to have loaded `url`.
@MainActor
private func arrive(_ tab: Nerda.Tab, at url: URL) async throws {
    for _ in 0..<200 {
        if tab.webView.url == url, !tab.webView.isLoading { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("never got to \(url)")
}

/// Quit, crash or rebuild, the tabs come back as they were: in order, the
/// same one on screen, each with its history. Only that one loads; the rest
/// sleep, keeping what they were, until they are shown.
@MainActor
@Test func tabsComeBackAsTheyWereLeft() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pages = try ["a", "b", "c"].map { name in
        let page = folder.appending(path: "\(name).html")
        try "<title>Page \(name)</title><p>\(name)</p>".write(to: page, atomically: true, encoding: .utf8)
        return page
    }
    let file = folder.appending(path: "session.json")

    let browser = Browser()
    browser.open(pages[0])
    try await arrive(browser.tabs[0], at: pages[0])
    browser.tabs[0].webView.load(URLRequest(url: pages[1]))
    try await arrive(browser.tabs[0], at: pages[1])
    browser.open(pages[2])
    try await arrive(browser.tabs[0], at: pages[2])
    browser.tabs[0].zoom(1)
    browser.selectedID = browser.tabs[1].id  // the one with history
    browser.sessionFile = file
    browser.saveSession()

    let restored = Browser()
    restored.restore(from: file)
    #expect(restored.tabs.map(\.title) == ["Page c", "Page b"])
    #expect(restored.tabs.allSatisfy { $0.isAsleep })
    #expect(restored.selectedID == restored.tabs[1].id)
    #expect(!restored.commandBarOpen)

    // Saved again before any wakes, nothing is lost.
    let again = folder.appending(path: "again.json")
    restored.sessionFile = again
    restored.saveSession()
    #expect(try Data(contentsOf: again) == (try Data(contentsOf: file)))

    let shown = restored.selected!
    try await arrive(shown, at: pages[1])
    #expect(shown.webView.canGoBack)
    #expect(restored.tabs[0].isAsleep)

    try await arrive(restored.tabs[0], at: pages[2])
    #expect(restored.tabs[0].webView.pageZoom > 1)
}

@MainActor
@Test func aSessionThatCantBeReadIsSetAsideNotOverwritten() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    try Data("{\"tabs\": [{\"url".utf8).write(to: file)

    let browser = Browser()
    browser.restore(from: file)
    #expect(browser.tabs.isEmpty)
    #expect(browser.commandBarOpen)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "session-unreadable.json").path))
}

/// Closing the window closes its tabs, but keeps them for next time, as
/// Chrome does; closing them one by one really closes them.
@MainActor
@Test func closingTheWindowKeepsItsTabsForNextTime() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")

    let browser = Browser()
    browser.restore(from: file)
    browser.open(somewhere)
    browser.open(URL(string: "https://github.com")!)
    browser.closeAll()
    browser.saveSession()
    let kept = try JSONDecoder().decode(Session.self, from: Data(contentsOf: file))
    #expect(kept.tabs.map(\.url.host) == ["github.com", "example.com"])

    // The window back: the tabs with it.
    browser.restore(from: file)
    #expect(browser.tabs.count == 2)
    while let tab = browser.tabs.first { browser.close(tab.id) }
    browser.saveSession()
    #expect(try JSONDecoder().decode(Session.self, from: Data(contentsOf: file)).tabs.isEmpty)
}

/// Addresses that can't be opened again (blob:, data:) aren't saved.
@MainActor
@Test func onlyTabsThatCanOpenAgainAreSaved() {
    let browser = Browser()
    browser.open(URL(string: "data:text/html,hello")!)
    browser.open(somewhere)
    #expect(browser.session.tabs.map(\.url.host) == ["example.com"])
    #expect(browser.session.selected == 0)
}

// MARK: - History

@MainActor
@Test func sitesAreSuggestedByTheStartOfTheirName() {
    let history = History()
    let now = Date.now
    for _ in 1...5 { history.visit(URL(string: "https://www.youtube.com/")!, title: "YouTube", at: now) }
    history.visit(URL(string: "https://www.youtube.com/watch?v=1")!, title: "A video", at: now)
    history.visit(URL(string: "https://yoga.example/poses")!, title: "Poses", at: now)
    history.visit(URL(string: "file:///tmp/notes.html")!, title: "Notes", at: now)
    history.visit(URL(string: "http://localhost:3000/app")!, title: "", at: now)

    let yo = history.sites(startingWith: "yo", now: now)
    #expect(yo.map(\.url.absoluteString) == ["https://www.youtube.com/", "https://yoga.example/"])
    #expect(yo[0].title == "YouTube")
    #expect(yo[1].title == "")  // its front page was never visited
    #expect(history.sites(startingWith: "www.you", now: now).first?.url.host() == "www.youtube.com")
    #expect(history.sites(startingWith: "localhost:3", now: now).first?.url.absoluteString == "http://localhost:3000/")
    #expect(history.sites(startingWith: "outube", now: now).isEmpty)
    #expect(history.visits.count == 4)  // not the file
}

/// Visited often long ago counts for less than a few times lately.
@MainActor
@Test func recentVisitsCountForMore() {
    let history = History()
    let now = Date.now
    for _ in 1...10 { history.visit(URL(string: "https://github.com/")!, title: "", at: now.addingTimeInterval(-60 * 86400)) }
    for _ in 1...3 { history.visit(URL(string: "https://gitlab.com/")!, title: "", at: now) }
    #expect(history.sites(startingWith: "git", now: now).map(\.url.host) == ["gitlab.com", "github.com"])
}

@MainActor
@Test func pagesAreFoundByAnyWordsOfTheirTitleOrAddress() {
    let history = History()
    history.visit(URL(string: "https://docs.swift.org/swift-book/")!, title: "The Swift Programming Language")
    history.visit(URL(string: "https://example.com/")!, title: "Example")
    history.name(URL(string: "https://example.com/")!, "Example Domain")
    #expect(history.pages(matching: "swift language").map(\.url.host) == ["docs.swift.org"])
    #expect(history.pages(matching: "swift-book").count == 1)
    #expect(history.pages(matching: "domain").first?.title == "Example Domain")
    #expect(history.pages(matching: "swift nothing").isEmpty)
}

@MainActor
@Test func historyIsKeptBetweenLaunchesButNotForever() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "history.json")
    let history = History()
    history.load(from: file)
    history.visit(URL(string: "https://old.example/")!, title: "Old", at: .now.addingTimeInterval(-100 * 86400))
    history.visit(URL(string: "https://new.example/")!, title: "New")
    history.save()

    let next = History()
    next.load(from: file)
    #expect(next.visits.keys.map(\.host) == ["new.example"])
    #expect(next.recent(5).first?.title == "New")
}

/// Typing the start of a site you go to makes it what Enter opens; the
/// search for what was typed comes right after.
@MainActor
@Test func typingTheStartOfASiteYouVisitGoesThere() {
    let history = History()
    for _ in 1...3 { history.visit(URL(string: "https://www.youtube.com/")!, title: "YouTube") }
    history.visit(URL(string: "https://www.youtube.com/watch?v=1")!, title: "Swift in 100 seconds")

    let yo = CommandBar.suggestions(for: "yo", guesses: ["yoga", "yo"], history: history)
    #expect(yo.map(\.url.absoluteString) == [
        "https://www.youtube.com/",
        "https://www.google.com/search?q=yo",
        "https://www.youtube.com/watch?v=1",
        "https://www.google.com/search?q=yoga",
    ])
    // Not from the middle of a word.
    #expect(CommandBar.suggestions(for: "tube", guesses: [], history: history).count == 1)

    // Typed out in full, the site is there once, not twice.
    #expect(CommandBar.suggestions(for: "youtube.com", guesses: [], history: history).map(\.url.absoluteString)
        == ["https://www.youtube.com/", "https://www.youtube.com/watch?v=1"])
    // Words are a search first, with the pages that match them after.
    #expect(CommandBar.suggestions(for: "swift seconds", guesses: [], history: history).map(\.url.absoluteString) == [
        "https://www.google.com/search?q=swift%20seconds",
        "https://www.youtube.com/watch?v=1",
    ])
    // Nothing typed: the sites you go to.
    #expect(CommandBar.suggestions(for: "", guesses: [], history: history).map(\.title) == ["YouTube"])
    // Nothing visited: what is typed.
    #expect(CommandBar.suggestions(for: "yo", guesses: [], history: History()).count == 1)
}

/// A page is put in history once it is there, including one that changes
/// its own address (as YouTube does going to a video); an address that fails
/// to open never is.
@MainActor
@Test func visitsAreRecordedOnceThePageIsThere() async throws {
    let browser = Browser()
    browser.open(somewhere)
    let tab = browser.tabs[0]
    let page = URL(string: "https://example.com/")!
    try await arrive(tab, at: page)
    #expect(History.shared.visits[page]?.count ?? 0 > 0)
    #expect(History.shared.visits[page]?.title == "Example Domain")

    let next = URL(string: "https://example.com/visit-\(UUID().uuidString)")!
    _ = try await tab.webView.callAsyncJavaScript("history.pushState({}, '', '\(next.path())')", contentWorld: .page)
    try await Task.sleep(for: .milliseconds(100))
    #expect(History.shared.visits[next]?.count == 1)

    let refused = URL(string: "http://127.0.0.1:9/")!
    tab.webView.load(URLRequest(url: refused))
    for _ in 0..<100 where tab.failure == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(tab.failure != nil)
    #expect(History.shared.visits[refused] == nil)
}
