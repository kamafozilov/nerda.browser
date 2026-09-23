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
