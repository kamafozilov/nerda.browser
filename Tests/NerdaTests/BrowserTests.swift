import Foundation
import ImageIO
import Network
import SwiftUI
import Testing
import WebKit
@testable import Nerda

private let somewhere = URL(string: "https://example.com")!

/// The updater offers a release only when its version is newer, by number
/// rather than by text: 0.0.10 comes after 0.0.9.
@Test func releasesAreNewerByNumber() {
    #expect(Version.isNewer("0.0.2", than: "0.0.1"))
    #expect(Version.isNewer("0.0.10", than: "0.0.9"))
    #expect(Version.isNewer("1.0.0", than: "0.9.9"))
    #expect(Version.isNewer("0.1", than: "0.0.9"))
    #expect(!Version.isNewer("0.0.1", than: "0.0.1"))
    #expect(!Version.isNewer("0.0.1", than: "0.0.2"))
}

/// What's New shows a release's notes by heading, a wrapped line kept with its item.
@Test func whatsNewReadsTheNotesByHeading() {
    let notes = "### Added\n\n- AI chats, `one` click away.\n- Bookmarks,\n  in folders.\n\n### Fixed\n\n- Renaming ends with a click."
    #expect(WhatsNew.sections(notes) == [
        .init(title: "Added", items: ["AI chats, `one` click away.", "Bookmarks, in folders."]),
        .init(title: "Fixed", items: ["Renaming ends with a click."]),
    ])
    #expect(WhatsNew.sections("Just a line.") == [.init(title: nil, items: ["Just a line."])])
}

/// An update is taken only with a Developer ID signature from Nerda's team:
/// an app Apple signed itself, or anyone else did, doesn't meet it. Only a
/// feed on this Mac is read over plain http.
@Test func updatesNeedNerdasDeveloperIDSignature() throws {
    let requirement = try #require(Updater.developerID(team: "ABCDE12345", identifier: "com.apple.calculator"))
    var code: SecStaticCode?
    #expect(SecStaticCodeCreateWithPath(URL(filePath: "/System/Applications/Calculator.app") as CFURL, [], &code) == errSecSuccess)
    #expect(SecStaticCodeCheckValidity(try #require(code), [], requirement) == errSecCSReqFailed)

    #expect(Updater.isSafe(URL(string: "https://api.github.com/repos/x/y/releases/latest")!))
    #expect(Updater.isSafe(URL(string: "http://127.0.0.1:8000/release.json")!))
    #expect(!Updater.isSafe(URL(string: "http://example.com/release.json")!))
    #expect(!Updater.isSafe(URL(string: "file:///tmp/Nerda.zip")!))
}

@MainActor
@Test func updateStatusDistinguishesResultsAndBusyWork() {
    let states: [Updater.State] = [.idle, .checking, .upToDate, .available("0.0.10"), .installing, .failed("Connection failed.")]
    #expect(states.map(\.isBusy) == [false, true, false, false, true, false])
    #expect(Set(states.map(\.detail)).count == states.count)
    #expect(Updater.State.available("0.0.10").detail.contains("0.0.10"))
    #expect(Updater.State.failed("Connection failed.").detail == "Connection failed.")
    #expect(SettingsPage.general.matches("updates"))
    #expect(SettingsPage.general.matches("version"))
    #if DEBUG
    let updater = Updater()
    updater.check(asked: true)
    #expect(!updater.canCheck && updater.state == .idle)
    #endif
}

@MainActor
@Test func externalLinksOpenWithoutReplacingExistingTabs() {
    let browser = Browser()
    browser.newTab()
    let blank = browser.selectedID
    let window = NSWindow()
    window.isReleasedWhenClosed = false
    let delegate = AppDelegate(window: window, browser: browser)
    defer {
        window.close()
        browser.closeAll()
    }
    browser.commandBarOpen = true
    browser.editingAddress = true
    let http = URL(string: "http://127.0.0.1:1/plain")!
    let https = URL(string: "https://127.0.0.1:1/secure")!
    delegate.application(.shared, open: [URL(string: "javascript:alert(1)")!, http, https])
    #expect(browser.tabs.map(\.url) == [https, http])
    #expect(browser.tabs.last?.id == blank)
    #expect(!browser.commandBarOpen && !browser.editingAddress && window.isVisible)

    window.orderOut(nil)
    delegate.application(.shared, open: [URL(string: "file:///tmp/page.html")!, URL(string: "https:/missing-host")!])
    #expect(browser.tabs.count == 2 && !window.isVisible)
    delegate.application(.shared, open: [http])
    #expect(browser.tabs.map(\.url) == [http, https, http] && window.isVisible)
    #expect(SettingsPage.general.matches("default browser"))
}

/// Closing the tab on screen goes back to the one on screen before it,
/// wherever it is in the list, and on back down the tabs as they were seen.
@MainActor
@Test func closingTabsGoesBackToTheTabBefore() {
    let browser = Browser()
    for _ in 1...4 { browser.open(somewhere) }
    let ids = browser.tabs.map(\.id)  // newest first, each seen as it opened
    browser.select(ids[1])
    browser.select(ids[3])

    // A tab that isn't showing goes without moving the selection.
    browser.close(ids[0])
    #expect(browser.selectedID == ids[3])

    // The bottom tab hands back to the one seen before it, not the one above.
    browser.close(ids[3])
    #expect(browser.selectedID == ids[1])
    browser.close(ids[1])
    #expect(browser.selectedID == ids[2])

    // …and the last one leaves a new tab, asking where to go next.
    browser.close(ids[2])
    #expect(browser.tabs.count == 1)
    #expect(browser.selected?.isBlank == true)
}

/// A new tab opens at the top, far from a tab down the list; closed, used or
/// not, it goes back down there, not to the tab under it. Went elsewhere
/// since, it goes back there instead.
@MainActor
@Test func closingANewTabGoesBackWhereYouWere() {
    let browser = Browser()
    for _ in 1...3 { browser.open(somewhere) }
    let (top, middle, bottom) = (browser.tabs[0].id, browser.tabs[1].id, browser.tabs[2].id)

    browser.select(bottom)
    browser.newTab()
    browser.go(to: somewhere)
    browser.closeSelectedTab()
    #expect(browser.selectedID == bottom)

    browser.newTab()
    let new = browser.selectedID!
    browser.select(middle)
    browser.select(new)
    browser.closeSelectedTab()
    #expect(browser.selectedID == middle)
    #expect(browser.tabs.map(\.id) == [top, middle, bottom])
}

/// A new tab has no page until it goes somewhere, and then is a tab like any other.
@MainActor
@Test func aNewTabGoesWhereItIsTold() {
    let browser = Browser()
    browser.open(somewhere)
    browser.newTab()
    let tab = browser.tabs[0]
    #expect(browser.selectedID == tab.id && tab.isBlank && tab.title == "New Tab")
    #expect(browser.session.tabs.count == 1)

    // It can't be pinned: it is nowhere.
    browser.setPinned(true, tab.id)
    #expect(!tab.isPinned)

    browser.go(to: somewhere)
    #expect(browser.tabs.count == 2)
    #expect(!tab.isBlank && tab.title == "example.com")
}

/// Each ⌘T is a tab of its own, and closing one unused goes back to the tab
/// it was opened from.
@MainActor
@Test func eachNewTabIsATabOfItsOwn() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    let (top, bottom) = (browser.tabs[0].id, browser.tabs[1].id)

    browser.selectedID = bottom
    browser.newTab()
    browser.closeSelectedTab()
    #expect(browser.tabs.map(\.id) == [top, bottom])
    #expect(browser.selectedID == bottom)

    browser.newTab()
    browser.newTab()
    browser.selectedID = top
    #expect(browser.tabs.count == 4)
}

/// The switcher offers the open tabs first, the one seen last first, then the rest.
@MainActor
@Test func theSwitcherOffersOpenTabsFirst() {
    func tab(_ url: String, _ title: String) -> Nerda.Tab {
        Nerda.Tab(restoring: Session.Tab(url: URL(string: url)!, title: title, state: nil, zoom: 1, pinned: nil, home: nil))
    }
    let docs = tab("https://docs.swift.org/", "Swift Docs")
    let mail = tab("https://mail.example/", "Inbox")
    mail.lastSeen = .now.addingTimeInterval(-60)
    let tabs = [mail, docs, Nerda.Tab()]

    let all = CommandBar.suggestions(for: "", guesses: [], history: History(), tabs: tabs)
    #expect(all.map(\.tab) == [docs.id, mail.id])

    let swift = CommandBar.suggestions(for: "swift", guesses: [], history: History(), tabs: tabs)
    #expect(swift.first?.tab == docs.id)
    #expect(swift.count == 2)
    #expect(swift.last?.isSearch == true)

    // Two tabs on one address are both there to go to.
    let again = tab("https://docs.swift.org/", "Swift Docs")
    #expect(CommandBar.suggestions(for: "", guesses: [], history: History(), tabs: [docs, again]).count == 2)
}

/// A closed tab takes its page with it: nothing else may keep it alive.
@MainActor
@Test func closedTabsAreFreed() {
    let browser = Browser()
    weak var tab: Nerda.Tab?
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

/// …also from the window, where the sidebar's rows showed it.
@MainActor
@Test func closedTabsAreFreedFromTheWindow() async throws {
    let browser = Browser()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
    window.orderFront(nil)
    defer { window.close() }
    weak var tab: Nerda.Tab?
    autoreleasepool {
        browser.open(somewhere)
        tab = browser.tabs[0]
    }
    try await Task.sleep(for: .milliseconds(500))
    autoreleasepool { withAnimation(.slide) { browser.close(browser.tabs[0].id) } }
    try await Task.sleep(for: .seconds(1))
    #expect(tab == nil)
}

/// A closed tab's page goes quiet at once, even while something still holds it.
@MainActor
@Test func closedTabsStopPlaying() async throws {
    // A second of silence, looped: playing, as far as WebKit is concerned.
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let samples = 8000
    var wav = Data()
    func put(_ value: Int, _ size: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0.prefix(size)) } }
    wav.append(contentsOf: "RIFF".utf8); put(36 + samples, 4)
    wav.append(contentsOf: "WAVEfmt ".utf8); put(16, 4); put(1, 2); put(1, 2); put(8000, 4); put(8000, 4); put(1, 2); put(8, 2)
    wav.append(contentsOf: "data".utf8); put(samples, 4)
    wav.append(Data(repeating: 128, count: samples))
    try wav.write(to: folder.appending(path: "tone.wav"))
    let page = folder.appending(path: "page.html")
    try #"<video src="tone.wav" loop autoplay></video>"#.write(to: page, atomically: true, encoding: .utf8)

    let browser = Browser()
    browser.open(page)
    let held = browser.tabs[0].webView
    for _ in 0..<100 where await held.requestMediaPlaybackState() != .playing {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await held.requestMediaPlaybackState() == .playing)

    browser.close(browser.tabs[0].id)
    #expect(await held.requestMediaPlaybackState() == .suspended)
}

@MainActor
@Test func aTabIsNamedForItsSiteUntilThePageSaysOtherwise() {
    #expect(Tab(url: URL(string: "https://www.github.com/apple")!).title == "github.com")
    #expect(Tab(url: URL(string: "file:///tmp/notes.html")!).title == "file:///tmp/notes.html")
    #expect(Tab().title == "New Tab")
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
    browser.select(opener.id)
    let popup = browser.webView(opener.webView, createWebViewWith: WKWebViewConfiguration(),
                                for: WKNavigationAction(), windowFeatures: WKWindowFeatures())
    #expect(browser.selected?.webView === popup)

    browser.close(browser.selectedID!)
    #expect(browser.selectedID == opener.id)
}

/// A page opens a window only from a click or a key: one it opens on its
/// own, as it loads, never comes.
@MainActor
@Test func pagesOpenWindowsOnlyWhenAsked() async throws {
    let browser = Browser()
    let tab = Tab()
    browser.add(tab)
    tab.webView.loadHTMLString("<script>window.open('https://example.com/')</script>", baseURL: somewhere)
    while tab.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(browser.tabs.count == 1)
}

/// Only this Mac's own servers are let through with a certificate of their
/// own: nothing can be in between there.
@Test(arguments: [
    ("localhost", true), ("app.localhost", true), ("127.0.0.1", true), ("127.1.2.3", true), ("::1", true), ("[::1]", true),
    ("localhost.example.com", false), ("128.0.0.1", false), ("127.0.0.256", false), ("127.evil.com", false), ("192.168.1.1", false),
])
func onlyThisMacIsTrustedAsItIs(host: String, trusted: Bool) {
    #expect(Browser.isThisMac(host) == trusted)
}

/// A tab out of sight can't bring itself forward with an alert: it waits
/// for you to go to it.
@MainActor
@Test func aTabOutOfSightWaitsToAsk() async throws {
    let browser = Browser()
    let tab = Tab()
    browser.add(tab)
    browser.add(Tab())
    let shown = browser.selectedID
    tab.webView.loadHTMLString("<script>alert('Look here')</script>", baseURL: somewhere)
    try await Task.sleep(for: .milliseconds(500))
    #expect(browser.selectedID == shown)
    browser.close(tab.id)
}

/// A mouse's side buttons go back and forward, as a swipe does.
@MainActor
@Test func aMousesSideButtonsGoBackAndForward() async throws {
    let page = Tab().webView
    let one = URL(string: "data:text/html,one")!, two = URL(string: "data:text/html,two")!
    for url in [one, two] {
        page.load(URLRequest(url: url))
        for _ in 0..<100 where page.url != url || page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    }
    func press(_ button: UInt32, until url: URL) async throws {
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: button)!)!
        page.otherMouseDown(with: NSEvent(cgEvent: event)!)
        for _ in 0..<100 where page.url != url || page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.url == url)
    }
    try await press(3, until: one)
    try await press(4, until: two)
}

/// A middle click on a link opens it in a tab of its own, behind this one.
@MainActor
@Test func aMiddleClickOpensTheLinkBehind() async throws {
    let browser = Browser()
    let tab = Tab()
    browser.add(tab)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                          backing: .buffered, defer: false)
    let page = tab.webView
    page.frame = window.contentView!.bounds
    window.contentView!.addSubview(page)
    page.loadHTMLString(#"<a href="https://example.com/elsewhere" style="position:fixed;inset:0">x</a><script>window.ready = true</script>"#, baseURL: somewhere)
    for _ in 0..<100 where try await page.callAsyncJavaScript("return window.ready === true", contentWorld: .page) as? Bool != true {
        try await Task.sleep(for: .milliseconds(20))
    }
    for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
        // The middle button: AppKit makes "other" mouse events as button 0.
        let made = NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: 150), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: type == .otherMouseDown ? 1 : 0)!.cgEvent!
        made.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let event = NSEvent(cgEvent: made)!
        if type == .otherMouseDown { page.otherMouseDown(with: event) } else { page.otherMouseUp(with: event) }
    }
    for _ in 0..<100 where browser.tabs.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
    // And the page itself stays where it was.
    try await Task.sleep(for: .milliseconds(300))
    #expect(browser.tabs.map(\.site?.absoluteString) == ["https://example.com/elsewhere", "https://example.com/"])
    #expect(browser.selectedID == tab.id)
}

/// The address bar wears the page's top edge, sampled anew from a snapshot
/// once light or dark mode switches (WebKit samples it once a load): the one
/// colour across it, near enough, or none.
@MainActor
@Test func aPagesTopEdgeIsOneColourOrNone() {
    func strip(_ colors: NSColor...) -> NSImage {
        NSImage(size: NSSize(width: 100, height: 1), flipped: false) { rect in
            for (i, color) in colors.enumerated() {
                color.setFill()
                rect.divided(atDistance: rect.width / CGFloat(colors.count) * CGFloat(i), from: .minXEdge).remainder.fill()
            }
            return true
        }
    }
    // Claude's sidebar and page, a shade apart.
    let sidebar = NSColor(srgbRed: 251 / 255, green: 251 / 255, blue: 249 / 255, alpha: 1)
    let page = NSColor(srgbRed: 252 / 255, green: 252 / 255, blue: 251 / 255, alpha: 1)
    #expect(Tab.color(across: strip(sidebar, page)).map(AddressBar.colorScheme(of:)) == .light)
    #expect(Tab.color(across: strip(.black)).map(AddressBar.colorScheme(of:)) == .dark)
    #expect(Tab.color(across: strip(page, .black)) == nil)
}

/// With no tab seen before it, as just after launch, the screen goes to the
/// tab that slides into place, or at the bottom to the one above.
@MainActor
@Test func closingTheOnlyTabSeenHandsOnByPlace() {
    let browser = Browser()
    for _ in 1...3 { browser.add(Nerda.Tab(), inBackground: true) }
    let (top, middle, bottom) = (browser.tabs[0].id, browser.tabs[1].id, browser.tabs[2].id)
    browser.select(middle)
    browser.close(middle)
    #expect(browser.selectedID == bottom)
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

/// A path to a file that is there opens the file; one to nothing is searched for.
@Test func typedPathOpensTheFile() {
    #expect(Address.url(from: "/etc/hosts") == URL(fileURLWithPath: "/etc/hosts"))
    #expect(Address.url(from: "/no/such/file.mp4")?.isFileURL == false)
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
    browser.closeAll()
    #expect(browser.tabs.isEmpty)
    #expect(browser.selectedID == nil)
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

/// Pages see nothing of Nerda that Safari doesn't show them: no
/// `window.webkit`, the mark of an app's web view, which Google answers
/// with CAPTCHAs.
@MainActor
@Test func pagesDontSeeTheBrowser() async throws {
    let page = Tab().webView
    page.loadHTMLString("<p>x</p>", baseURL: somewhere)
    while page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    #expect(try await page.callAsyncJavaScript("return typeof window.webkit", contentWorld: .page) as? String == "undefined")
}

/// A page's full screen still reaches the browser, which takes a tab out of
/// sight back out of it.
@MainActor
@Test func aTabOutOfSightIsKeptOutOfFullScreen() async throws {
    let browser = Browser()
    let tab = Tab()
    browser.add(tab)
    browser.add(Tab())
    let page = tab.webView
    page.loadHTMLString(#"<div id="box">x</div>"#, baseURL: somewhere)
    while page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    func shown() async throws -> Bool {
        try await page.callAsyncJavaScript("return document.fullscreenElement !== null", contentWorld: .page) as? Bool == true
    }
    _ = try await page.callAsyncJavaScript("await box.requestFullscreen()", contentWorld: .page)
    for _ in 0..<50 {
        guard try await shown() else { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await shown() == false)
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
    // A page's title comes a moment after it has loaded.
    for _ in 0..<100 where browser.tabs.map(\.title) != ["Page c", "Page b"] {
        try await Task.sleep(for: .milliseconds(20))
    }
    browser.sessionFile = file
    browser.saveSession()

    let restored = Browser()
    restored.restore(from: file)
    #expect(restored.tabs.map(\.title) == ["Page c", "Page b"])
    #expect(restored.tabs.allSatisfy { $0.isAsleep })
    #expect(restored.selectedID == restored.tabs[1].id)

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
    #expect(browser.tabs.count == 1 && browser.selected?.isBlank == true)
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
    #expect(kept.tabs.map(\.url?.host) == ["github.com", "example.com"])

    // The window back: the tabs with it.
    browser.restore(from: file)
    #expect(browser.tabs.count == 2)
    while let tab = browser.tabs.first(where: { !$0.isBlank }) { browser.close(tab.id) }
    browser.saveSession()
    #expect(try JSONDecoder().decode(Session.self, from: Data(contentsOf: file)).tabs.isEmpty)
}

/// Addresses that can't be opened again (blob:, data:) aren't saved.
@MainActor
@Test func onlyTabsThatCanOpenAgainAreSaved() {
    let browser = Browser()
    browser.open(URL(string: "data:text/html,hello")!)
    browser.open(somewhere)
    #expect(browser.session.tabs.map(\.url?.host) == ["example.com"])
    #expect(browser.session.selected == 0)
}

/// Nerda starts on the tab it was left on; left on a new tab, on a new tab,
/// the others behind it.
@MainActor
@Test func itStartsWhereItWasLeft() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    let saved = Session.Tab(url: somewhere, title: "Example", state: nil, zoom: 1, pinned: nil, home: nil)

    try JSONEncoder().encode(Session(tabs: [saved], selected: nil)).write(to: file)
    let onNewTab = Browser()
    onNewTab.restore(from: file)
    #expect(onNewTab.tabs.count == 2 && onNewTab.selected?.isBlank == true)

    try JSONEncoder().encode(Session(tabs: [saved], selected: 0)).write(to: file)
    let onPage = Browser()
    onPage.restore(from: file)
    #expect(onPage.tabs.count == 1 && onPage.selected?.title == "Example")
}

/// The settings tab comes back too, on the page it was left on, and on screen if it was.
@MainActor
@Test func theSettingsTabComesBack() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")

    let browser = Browser()
    browser.sessionFile = file
    browser.open(somewhere)
    browser.openSettings()
    browser.saveSession()

    let restored = Browser()
    restored.restore(from: file)
    #expect(restored.tabs.count == 2)
    #expect(restored.selected?.settings == .general)
    #expect(restored.tabs[1].title == "example.com")
}

@MainActor
@Test func aTabKeepsTheNameItWasGiven() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")

    let browser = Browser()
    browser.sessionFile = file
    browser.open(somewhere)
    let id = try #require(browser.selectedID)
    browser.rename(id, to: "  Reading  ")
    #expect(browser.selected?.title == "Reading")
    browser.saveSession()

    let restored = Browser()
    restored.restore(from: file)
    #expect(restored.tabs.first?.title == "Reading")

    // Nothing typed gives the tab back its page's title.
    browser.rename(id, to: " ")
    #expect(browser.selected?.title == "example.com")
}

@MainActor
@Test func historyListsPagesByDayLatestFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let day = Date(timeIntervalSince1970: 1_790_000_000)
    let visit = { (url: String, title: String, hoursAgo: Double) in
        History.Visit(url: URL(string: url)!, title: title, count: 1, last: day.addingTimeInterval(-hoursAgo * 3600))
    }
    let visits = [visit("https://a.com/", "Swift", 30), visit("https://b.com/", "News", 1), visit("https://c.com/", "Swift book", 2)]

    let days = HistoryPage.days(of: visits, matching: "", calendar: calendar)
    #expect(days.map { $0.visits.map(\.title) } == [["News", "Swift book"], ["Swift"]])
    #expect(HistoryPage.days(of: visits, matching: "swift", calendar: calendar).flatMap(\.visits).count == 2)
    #expect(HistoryPage.days(of: visits, matching: "b.com", calendar: calendar).flatMap(\.visits).map(\.title) == ["News"])
}

/// The history page lays out one line at a time: each day's heading, then
/// its pages, the first and last of which round off the day's box.
@MainActor
@Test func historyLinesRoundOffEachDay() {
    let day = Date(timeIntervalSince1970: 1_790_000_000)
    let visit = { (url: String) in History.Visit(url: URL(string: url)!, title: "", count: 1, last: day) }
    let lines = HistoryPage.lines(of: [(day, [visit("https://a.com/"), visit("https://b.com/"), visit("https://c.com/")]),
                                       (day.addingTimeInterval(-86400), [visit("https://d.com/")])])
    let marks = lines.map { line in
        switch line {
        case .day: "day"
        case .page(_, let first, let last): first && last ? "only" : first ? "first" : last ? "last" : "middle"
        }
    }
    #expect(marks == ["day", "first", "middle", "last", "day", "only"])
}

@MainActor
@Test func theHistoryTabComesBackAndIsOnlyOne() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")

    let browser = Browser()
    browser.sessionFile = file
    browser.openHistory()
    browser.open(somewhere)
    browser.openHistory()
    #expect(browser.tabs.filter(\.showsHistory).count == 1)
    #expect(browser.selected?.showsHistory == true)
    browser.saveSession()

    let restored = Browser()
    restored.restore(from: file)
    #expect(restored.selected?.title == "History")
}

// MARK: - Reliability

/// A page whose process dies is loaded again; if it dies again straight
/// away, it stops, and says so, instead of reloading for ever.
@MainActor
@Test func aPageThatKeepsCrashingStops() {
    let browser = Browser()
    browser.open(somewhere)
    let tab = browser.tabs[0]
    browser.webViewWebContentProcessDidTerminate(tab.webView)
    #expect(tab.failure == nil)
    browser.webViewWebContentProcessDidTerminate(tab.webView)
    #expect(tab.failure?.url.host == "example.com")

    // Much later, a crash is a one-off again.
    tab.failure = nil
    tab.crashed = .now.addingTimeInterval(-120)
    browser.webViewWebContentProcessDidTerminate(tab.webView)
    #expect(tab.failure == nil)
}

/// A page out of sight that crashes sleeps, and loads when next shown.
@MainActor
@Test func aCrashedTabOutOfSightWaitsToBeShown() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    let hidden = browser.tabs[1]
    browser.webViewWebContentProcessDidTerminate(hidden.webView)
    #expect(hidden.isAsleep)
    #expect(hidden.failure == nil)
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

/// Pages visited or renamed after the history was first looked through are
/// found as they are now, the best first.
@MainActor
@Test func pagesAreFoundAsTheyChange() {
    let history = History()
    let now = Date.now
    let first = URL(string: "https://a.example/")!
    history.visit(first, title: "Apples", at: now.addingTimeInterval(-60))
    #expect(history.pages(matching: "apples").count == 1)

    history.name(first, "Pears")
    history.visit(URL(string: "https://b.example/")!, title: "Plums", at: now)
    #expect(history.pages(matching: "apples").isEmpty)
    #expect(history.pages(matching: "pears").map(\.url) == [first])
    #expect(history.recent(2).map(\.title) == ["Plums", "Pears"])
    #expect(history.pages(matching: "example", limit: 1, now: now).map(\.title) == ["Plums"])
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
    // Nothing typed: the sites you went to last, each once, as the page last seen.
    history.visit(URL(string: "https://mover.uz/")!, title: "Mover.uz")
    #expect(CommandBar.suggestions(for: "", guesses: [], history: history).map(\.title)
        == ["Mover.uz", "Swift in 100 seconds"])
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

// MARK: - Pinned tabs

/// Pinned tabs sit above the rest in the order pinned, never sleep, outlast
/// ⌘W, and come back pinned, and loaded, at the next launch.
@MainActor
@Test func pinnedTabsStayOnTopAwakeAndOpenAgain() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    let browser = Browser()
    browser.sessionFile = file
    for site in ["https://a.test", "https://b.test", "https://c.test"] { browser.open(URL(string: site)!) }
    let (c, b, a) = (browser.tabs[0].id, browser.tabs[1].id, browser.tabs[2].id)

    browser.setPinned(true, a)
    browser.setPinned(true, c)
    #expect(browser.tabs.map(\.id) == [a, c, b])
    // A new tab opens under the pins, and ⌘1 is still the first tile.
    browser.open(somewhere)
    #expect(browser.tabs[2].title == "example.com")
    browser.selectTab(number: 1)
    #expect(browser.selectedID == a)

    browser.selectedID = browser.tabs[2].id
    browser.sleepIdleTabs(unseenFor: 0)
    for _ in 0..<100 where !browser.tabs[3].isAsleep { try await Task.sleep(for: .milliseconds(20)) }
    #expect(browser.tabs[3].isAsleep)
    #expect(!browser.tabs[0].isAsleep && !browser.tabs[1].isAsleep)

    browser.selectedID = c
    browser.closeSelectedTab()
    #expect(browser.tabs.contains { $0.id == c })
    #expect(browser.selectedID == browser.tabs[2].id)

    browser.saveSession()
    let restored = Browser()
    restored.restore(from: file)
    #expect(restored.tabs.map(\.isPinned) == [true, true, false, false])
    #expect(restored.tabs.map(\.title) == ["a.test", "c.test", "example.com", "b.test"])
    #expect(!restored.tabs[0].isAsleep && !restored.tabs[1].isAsleep)
    #expect(restored.tabs[3].isAsleep)

    // Unpinned, a tab goes to the top of the list.
    restored.setPinned(false, restored.tabs[0].id)
    #expect(restored.tabs.map(\.title) == ["c.test", "a.test", "example.com", "b.test"])
    #expect(restored.tabs.map(\.isPinned) == [true, false, false, false])
}

/// A pinned tab goes back to where it was pinned (its tile double-clicked),
/// however far it has gone since, and still does after a relaunch.
@MainActor
@Test func pinnedTabsGoBackToWhereTheyWerePinned() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pages = try ["home", "away"].map { name in
        let page = folder.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: page, atomically: true, encoding: .utf8)
        return page
    }
    let file = folder.appending(path: "session.json")

    let browser = Browser()
    browser.open(pages[0])
    try await arrive(browser.tabs[0], at: pages[0])
    browser.setPinned(true, browser.tabs[0].id)
    browser.tabs[0].webView.load(URLRequest(url: pages[1]))
    try await arrive(browser.tabs[0], at: pages[1])
    browser.sessionFile = file
    browser.saveSession()

    let restored = Browser()
    restored.restore(from: file)
    let tab = restored.tabs[0]
    try await arrive(tab, at: pages[1])
    tab.goHome()
    try await arrive(tab, at: pages[0])

    // Unpinned, it has nowhere to go back to.
    restored.setPinned(false, tab.id)
    #expect(tab.home == nil)
}

/// Dragged, a tab takes the place it is let go at, within its own kind or
/// across into the other, and stays in that order.
@MainActor
@Test func tabsAreDraggedIntoAnotherOrder() {
    let browser = Browser()
    for site in ["https://a.test", "https://b.test", "https://c.test", "https://d.test"] { browser.open(URL(string: site)!) }
    func titles() -> [String] { browser.tabs.map { ($0.isPinned ? "*" : "") + $0.title } }
    #expect(titles() == ["d.test", "c.test", "b.test", "a.test"])

    browser.move(browser.tabs[3].id, pinned: false, to: 1)
    #expect(titles() == ["d.test", "a.test", "c.test", "b.test"])
    browser.move(browser.tabs[0].id, pinned: false, to: .max)
    #expect(titles() == ["a.test", "c.test", "b.test", "d.test"])

    // Into the tiles, where it was let go; tiles among themselves; and back out.
    browser.move(browser.tabs[2].id, pinned: true, to: 0)
    browser.move(browser.tabs[2].id, pinned: true, to: 0)
    #expect(titles() == ["*c.test", "*b.test", "a.test", "d.test"])
    browser.move(browser.tabs[0].id, pinned: true, to: 1)
    #expect(titles() == ["*b.test", "*c.test", "a.test", "d.test"])
    browser.move(browser.tabs[1].id, pinned: false, to: 1)
    #expect(titles() == ["*b.test", "a.test", "c.test", "d.test"])
}

/// An icon only the page names (the site's /favicon.ico is empty) is still
/// there at the next launch, while the tab sleeps and its page never loads.
@MainActor
@Test func iconsFoundInThePageOutlastTheRun() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let icon = folder.appending(path: "icon.png")
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { NSColor.red.setFill(); $0.fill(); return true }
    try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: icon)
    let site = "https://icon.invalid"

    let before = Favicons()
    before.folder = folder.appending(path: "Favicons")
    await before.load(site, icon: icon)
    #expect(before.images[site] != nil)

    let after = Favicons()
    after.folder = before.folder
    await after.load(site)
    #expect(after.images[site] != nil)
    #expect(after.tints[site]?.colors.count == 1)

    // At launch, read at once for the tabs coming back, before any frame.
    let launch = Favicons()
    launch.folder = before.folder
    launch.preload([URL(string: site + "/some/page")!])
    #expect(launch.images[site] != nil)
}

/// A pinned tile wears its icon's colours: each hue in it, or, for a dark
/// icon without any, its grey; a light grey one has none.
@MainActor
@Test func tilesTakeTheirIconsColours() throws {
    func icon(_ colors: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            for (i, color) in colors.enumerated() {
                color.setFill()
                rect.divided(atDistance: rect.width / CGFloat(colors.count) * CGFloat(i), from: .minXEdge).remainder.fill()
            }
            return true
        }
    }
    let google = try #require(Tint(icon([.systemRed, .systemYellow, .systemGreen, .systemBlue])))
    #expect(!google.isGrey && google.colors.count == 4)
    let youtube = try #require(Tint(icon([.red])))
    #expect(!youtube.isGrey && youtube.colors.count == 1 && youtube.colors[0].redComponent > 0.9)
    // A black square (X's) is kept as it is; a black mark on nothing (GitHub's) is drawn light on a tile.
    let square = try #require(Tint(icon([.black])))
    #expect(square.isGrey && !square.isMark)
    let mark = try #require(Tint(NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
        return true
    }))
    #expect(mark.isGrey && mark.isMark)
    #expect(Tint(icon([.white])) == nil)
}

// MARK: - Passwords

/// A site's accounts are offered across its subdomains, its own host's
/// first, and never on another site: not one next door on a shared host, a
/// country's second level, or an address.
@Test func savedPasswordsBelongToTheirSite() {
    let accounts = [
        Account(host: "example.com", user: "a"),
        Account(host: "login.example.com", user: "b"),
        Account(host: "other.com", user: "c"),
        Account(host: "alice.github.io", user: "d"),
        Account(host: "shop.co.uz", user: "e"),
        Account(host: "10.0.0.1", user: "f"),
        Account(host: "alice.myshopify.com", user: "g"),
        Account(host: "docs.alice.notion.site", user: "h"),
    ]
    #expect(Site.matching(accounts, "WWW.Login.Example.com").map(\.user) == ["b", "a"])
    #expect(Site.matching(accounts, "bob.github.io").isEmpty)
    #expect(Site.matching(accounts, "bank.co.uz").isEmpty)
    #expect(Site.matching(accounts, "mail.shop.co.uz").map(\.user) == ["e"])
    #expect(Site.matching(accounts, "10.0.0.2").isEmpty)
    // Shops and pages anyone can make under a shared name, from the public suffix list.
    #expect(Site.matching(accounts, "bob.myshopify.com").isEmpty)
    #expect(Site.matching(accounts, "alice.notion.site").map(\.user) == ["h"])
    #expect(Site.matching(accounts, "bob.notion.site").isEmpty)
}

/// A page that came over plain http, which anyone on the network in between
/// could have written, is offered only passwords last used on such a page.
/// Those kept before this read as kept over https.
@Test func plainHttpPagesGetNoPasswordKeptOverHttps() throws {
    let before = try JSONDecoder().decode([Vault.Name].self, from: Data(#"[{"host":"bank.com","user":"me","saved":0}]"#.utf8))
    let names = before + [Vault.Name(host: "router.lan", user: "admin", saved: .now, clear: true)]
    #expect(Vault.offered(names, clear: true).map(\.user) == ["admin"])
    #expect(Vault.offered(names, clear: false).map(\.user) == ["me", "admin"])
}

/// Exports as Passwords and Chrome write them: quoted fields with commas,
/// quotes and line breaks, a byte-order mark, and rows with nothing to keep.
@Test func exportedPasswordsAreReadIn() {
    let apple = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n"
        + "Google,https://accounts.google.com/,kama@gmail.com,\"p,a\"\"ss\",\"two\nlines\",\r\n"
        + "App,,someone,secret,,\r\n"
        + "Bank,www.bank.uz,me,,,\r\n"
    let logins = PasswordsFile.logins(in: apple)
    #expect(logins.count == 1)
    #expect(logins.first?.0 == Account(host: "accounts.google.com", user: "kama@gmail.com"))
    #expect(logins.first?.1 == "p,a\"ss")

    let chrome = "name,url,username,password,note\nx.com,https://www.x.com/login,kama,hunter2,\n"
    #expect(PasswordsFile.logins(in: chrome).first.map { [$0.0.host, $0.0.user, $0.1] } == ["x.com", "kama", "hunter2"])
    #expect(PasswordsFile.logins(in: "a,b\n1,2\n").isEmpty)
}

/// Nerda's pictures take turns, one a day: the same all day, the next one tomorrow.
@Test func newTabPicturesTakeTurnsByTheDay() {
    let pictures = ["a", "b", "c"].map { URL(filePath: "/\($0).heic") }
    let morning = Calendar.current.startOfDay(for: .now)
    let today = Backdrop.picture(for: morning, among: pictures)!
    #expect(Backdrop.picture(for: morning.addingTimeInterval(23 * 3600), among: pictures) == today)
    let tomorrow = Backdrop.picture(for: Calendar.current.date(byAdding: .day, value: 1, to: morning)!, among: pictures)!
    #expect(pictures.firstIndex(of: tomorrow) == (pictures.firstIndex(of: today)! + 1) % pictures.count)
    #expect(Backdrop.picture(for: morning, among: []) == nil)
}

/// A chosen picture is kept as a copy no bigger than asked; a file that
/// isn't a picture leaves the last one as it was.
@Test func aChosenPictureIsKeptSmall() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let big = folder.appending(path: "big.png")
    let context = CGContext(data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = CGImageDestinationCreateWithURL(big as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(out, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(out))

    let kept = folder.appending(path: "kept.heic")
    #expect(Backdrop.copy(big, to: kept, side: 2000))
    #expect(Backdrop.image(from: kept, side: 10_000)?.width == 2000)
    // With a small copy inside, for the picker.
    #expect(CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithURL(kept as CFURL, nil)!, 0, nil) != nil)

    let text = folder.appending(path: "notes.txt")
    try Data("not a picture".utf8).write(to: text)
    #expect(!Backdrop.copy(text, to: kept, side: 2000))
    #expect(Backdrop.image(from: kept, side: 10_000)?.width == 2000)
}

/// The wallpaper picked is kept by name, and shows that picture; one that has
/// gone (a picture no longer shipped, one of yours deleted) is Daily again.
@MainActor
@Test func aPickedWallpaperIsKept() {
    for wallpaper in [Wallpaper.daily, .chosen("x.heic"), .own("2-minoo.heic")] {
        #expect(Wallpaper(saved: wallpaper.saved) == wallpaper)
    }
    #expect(Wallpaper(saved: "chosen") == .chosen("new-tab-picture.heic"))
    #expect(Wallpaper(saved: "something else") == nil)

    let own = ["1-a.heic", "2-b.heic"].map { URL(filePath: "/\($0)") }
    let chosen = ["x.heic", "y.heic"].map { URL(filePath: "/mine/\($0)") }
    let today = Backdrop.picture(for: .now, among: own)
    #expect(Backdrop.file(for: .own("2-b.heic"), own: own, chosen: chosen, day: .now) == own[1])
    #expect(Backdrop.file(for: .chosen("y.heic"), own: own, chosen: chosen, day: .now) == chosen[1])
    #expect(Backdrop.file(for: .daily, own: own, chosen: chosen, day: .now) == today)
    #expect(Backdrop.file(for: .own("9-gone.heic"), own: own, chosen: chosen, day: .now) == today)
    #expect(Backdrop.file(for: .chosen("gone.heic"), own: own, chosen: chosen, day: .now) == today)
    #expect(Backdrop.title(of: .own("5-fuji-sunrise.heic")) == "Fuji Sunrise")
}

/// A picture is decoded big enough to fill the largest screen edge to edge,
/// a tall one on a wide screen taller than the screen.
@Test func aPictureFillsTheScreen() {
    let screen = CGSize(width: 3456, height: 2234)
    #expect(Backdrop.side(of: CGSize(width: 6000, height: 4000), covering: [screen]) == 3456)
    #expect(Backdrop.side(of: CGSize(width: 4000, height: 6000), covering: [screen]) == 5184)
    #expect(Backdrop.side(of: CGSize(width: 6000, height: 4000), covering: [screen, CGSize(width: 6016, height: 3384)]) == 6016)
}

/// ⌘, opens the settings in a tab of their own, and only ever one: asked again,
/// it goes back to it. The tab has no page, and going somewhere from it leaves them.
@MainActor
@Test func settingsOpenInOneTab() {
    let browser = Browser()
    browser.open(somewhere)
    browser.openSettings()
    let settings = browser.selected!
    #expect(settings.settings == .general)
    #expect(!settings.isBlank && !settings.hasPage)

    browser.open(somewhere)
    browser.openSettings()
    #expect(browser.selectedID == settings.id)
    #expect(browser.tabs.count(where: { $0.settings != nil }) == 1)

    settings.go(to: somewhere)
    #expect(settings.settings == nil && settings.hasPage)
}

// MARK: - Blocking

/// Filter lines become WebKit's rules: an ad server whole, a pattern that
/// spares the page itself, a site's own requests spared, a site let through,
/// and lines WebKit's rules can't say left out.
@Test func filterLinesBecomeContentRules() throws {
    let server = try #require(ContentRules.rule("||ads.example^$third-party"))
    let trigger = try #require(server.0["trigger"] as? [String: Any])
    #expect(trigger["url-filter"] as? String == "^[^:]+://+([^:/]+\\.)?ads\\.example[^a-zA-Z0-9_.%-]")
    #expect(trigger["load-type"] as? [String] == ["third-party"])
    #expect(trigger["resource-type"] == nil)
    #expect(server.1 == false)

    // Sites both named and excepted: WebKit takes one or the other.
    #expect(ContentRules.rule("/banner/*/ad.$domain=news.example|~sub.news.example") == nil)
    let spared = try #require(ContentRules.rule("/banner/*/ad.$domain=news.example"))
    let sparedTrigger = try #require(spared.0["trigger"] as? [String: Any])
    #expect(sparedTrigger["url-filter"] as? String == "/banner/.*/ad\\.")
    #expect(sparedTrigger["if-domain"] as? [String] == ["*news.example"])
    #expect(sparedTrigger["resource-type"] == nil)
    // Written for a site: its own requests are stopped too.
    #expect(sparedTrigger["load-type"] == nil)

    // For any site: only what comes from other sites, never a site's own
    // workings; unless the rule is about sites' own requests.
    let tracker = try #require(ContentRules.rule("||tracker.example/collect/"))
    #expect((tracker.0["trigger"] as? [String: Any])?["load-type"] as? [String] == ["third-party"])
    let own = try #require(ContentRules.rule("/ads/*.js$~third-party"))
    #expect((own.0["trigger"] as? [String: Any])?["load-type"] as? [String] == ["first-party"])

    // Bot checks are let through wherever they are.
    let checks = ContentRules.botChecks.split(separator: "\n").map { ContentRules.rule(String($0)) }
    #expect(checks.allSatisfy { $0?.1 == true })

    let site = try #require(ContentRules.rule("@@||site.example^$document"))
    #expect(site.1)
    #expect((site.0["trigger"] as? [String: Any])?["if-top-url"] as? [String] == [ContentRules.urlFilter("||site.example^")!])

    #expect(ContentRules.rule("example.com##.ad") == nil)
    #expect(ContentRules.rule("||x.example^$redirect=noop.js") == nil)
    #expect(ContentRules.rule("||x.example^$document") == nil)
    #expect(ContentRules.rule("/ads?[0-9]+/") == nil)
    #expect(ContentRules.rule("! a comment") == nil)
}

/// Exceptions come after the blocks they undo, and WebKit compiles the lot.
@MainActor
@Test func contentRulesCompile() async throws {
    let encoded = try #require(ContentRules.encode("""
        @@||good.example^$script
        ||bad.example^
        /banner/*/ad.$image,domain=news.example
        |https://track.example/pixel?|
        ||cdn.example/ads/*.js$script,~third-party
        """))
    let rules = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
    #expect(rules.map { ($0["action"] as? [String: String])?["type"] }.last == "ignore-previous-rules")
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try #require(WKContentRuleListStore(url: folder))
    let list = try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: encoded)
    #expect(list != nil)
}

/// Pages are let past WebKit's 60 frames a second (Tab.matchScreenRate), but
/// for Low Power Mode. Fails once WebKit takes the switch away or renames it.
@MainActor
@Test func pagesAreDrawnAtTheScreensRate() throws {
    let flag = try #require(Nerda.Tab.near60)
    let preferences = Nerda.Tab(url: somewhere).webView.configuration.preferences
    let get = NSSelectorFromString("_isEnabledForFeature:")
    typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    let near60 = unsafeBitCast(preferences.method(for: get), to: Getter.self)(preferences, get, flag)
    #expect(near60 == ProcessInfo.processInfo.isLowPowerModeEnabled)
}

/// An incognito window's tabs, a page's popups among them, keep their cookies
/// and site data in its store in memory, and suggest nothing from history.
@MainActor
@Test func incognitoTabsKeepToTheirStore() {
    let browser = Browser(dataStore: .nonPersistent())
    browser.open(somewhere)
    browser.newTab()
    #expect(browser.isPrivate && browser.tabs.allSatisfy(\.isPrivate))
    #expect(browser.tabs[1].webView.configuration.websiteDataStore === browser.dataStore)
    #expect(browser.history === History.empty)
    #expect(!Browser().isPrivate && Browser().history === History.shared)
}

/// Closing a window's last tab closes the window, as in other browsers.
@MainActor
@Test func closingTheLastTabClosesTheWindow() {
    let browser = Browser()
    let window = NSWindow()
    window.isReleasedWhenClosed = false
    browser.window = window
    window.orderFront(nil)
    browser.open(somewhere)
    browser.close(browser.tabs[0].id)
    #expect(!window.isVisible && browser.tabs.isEmpty)
}

/// Exercises compiled rules against real HTTP loads, without public sites or account data.
@MainActor
@Test func contentBlockingPreservesNavigationAndExceptions() async throws {
    let navigation = BlockerNavigation()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    server.newConnectionHandler = { connection in
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            MainActor.assumeIsolated {
                if let data, let path = String(decoding: data, as: UTF8.self).split(separator: " ").dropFirst().first {
                    navigation.requests.insert(String(path))
                }
            }
            let body = "/* fixture */"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    server.start(queue: .main)
    defer { server.cancel() }
    for _ in 0..<100 where server.port == nil || server.port == .any { try await Task.sleep(for: .milliseconds(20)) }
    let port = try #require(server.port?.rawValue)
    try #require(port > 0)
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try #require(WKContentRuleListStore(url: folder))
    let encoded = try #require(ContentRules.encode("""
        ||127.0.0.1^$~third-party
        /blocked-resource$xmlhttprequest
        /allowed-resource$xmlhttprequest
        @@/allowed-resource$xmlhttprequest
        /disabled-resource$xmlhttprequest,third-party
        /disabled-resource$third-party,badfilter,xmlhttprequest
        /frame-ad$subdocument,script
        """))
    let list = try #require(try await store.compileContentRuleList(forIdentifier: "navigation", encodedContentRuleList: encoded))
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let page = WKWebView(frame: .zero, configuration: configuration)
    page.navigationDelegate = navigation
    defer { page.stopLoading() }
    let url = URL(string: "http://127.0.0.1:\(port)/")!
    page.load(URLRequest(url: url))
    for _ in 0..<250 where !navigation.finished { try await Task.sleep(for: .milliseconds(20)) }
    try #require(navigation.finished && navigation.error == nil, "Fixture load failed: \(String(describing: navigation.error))")
    try #require(page.url == url)
    let blocker = Blocker()
    let previousSetting = UserDefaults.standard.object(forKey: "blockAdsAndTrackers")
    defer { UserDefaults.standard.set(previousSetting, forKey: "blockAdsAndTrackers") }
    blocker.isEnabled = true
    blocker.install(in: configuration.userContentController)
    blocker.use([list])
    navigation.finished = false
    page.reload()
    for _ in 0..<250 where !navigation.finished { try await Task.sleep(for: .milliseconds(20)) }
    try #require(navigation.finished && navigation.error == nil, "Blocked navigation: \(String(describing: navigation.error))")
    func fetch(_ path: String) async throws -> Bool {
        let result = try await page.callAsyncJavaScript("""
            try { return (await fetch(url, {cache: 'no-store'})).ok; } catch { return false; }
            """, arguments: ["url": "http://localhost:\(port)/\(path)"], contentWorld: .page)
        return result as? Bool == true
    }
    for (path, allowed) in [("blocked-resource", false), ("allowed-resource", true), ("disabled-resource", true)] {
        #expect(try await fetch(path) == allowed, "Unexpected request result for \(path)")
    }
    // The XHR filter must not stop a script at the same URL. A mixed
    // subdocument/script filter still blocks ad frames, and leaves other frames.
    for (element, path, allowed) in [("script", "blocked-resource", true), ("iframe", "frame-ad", false), ("iframe", "ordinary-frame", true)] {
        navigation.requests = []
        _ = try await page.callAsyncJavaScript("""
            await new Promise(resolve => {
                const node = document.createElement(element);
                node.onload = node.onerror = resolve;
                node.src = url;
                document.body.append(node);
                setTimeout(resolve, 1000);
            });
            """, arguments: ["element": element, "url": "http://localhost:\(port)/\(path)"], contentWorld: .page)
        #expect(navigation.requests.contains("/" + path) == allowed)
    }
    let unrelated = try #require(try await store.compileContentRuleList(forIdentifier: "unrelated",
        encodedContentRuleList: #"[{"trigger":{"url-filter":"/unrelated-resource"},"action":{"type":"block"}}]"#))
    configuration.userContentController.add(unrelated)
    blocker.isEnabled = false
    #expect(try await fetch("blocked-resource"))
    #expect(try await !fetch("unrelated-resource"))
    // A refresh while disabled stays disabled. Turning it back on uses the new list.
    let updated = try #require(try await store.compileContentRuleList(forIdentifier: "updated",
        encodedContentRuleList: ContentRules.encode("/updated-resource$xmlhttprequest")!))
    blocker.use([updated])
    #expect(try await fetch("updated-resource"))
    blocker.isEnabled = true
    #expect(try await !fetch("updated-resource"))
    #expect(try await fetch("blocked-resource"))
    #expect(try await !fetch("unrelated-resource"))
}

@Test func contentRuleTranslationKeepsFilterBoundaries() throws {
    let separator = try #require(ContentRules.urlFilter("||ads.example^"))
    let regex = try NSRegularExpression(pattern: separator)
    func matches(_ url: String) -> Bool {
        regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
    #expect(matches("https://ads.example/"))
    #expect(matches("https://sub.ads.example/path"))
    #expect(!matches("https://good.example/path/ads.example/banner"))
    #expect(!matches("https://notads.example/"))
    #expect(!matches("https://ads.example.evil/"))
    #expect(ContentRules.rule("||ads.example^$domain=") == nil)
    #expect(ContentRules.rule("||ads.example^$domain=*.example") == nil)
    #expect(ContentRules.rule("||ads.example^$redirect=https://example.com/noop.js") == nil)
    #expect(ContentRules.rule("||ads.example^$popup") == nil)
    let mixed = try #require(ContentRules.rule("@@/collect$domain=example.com|~private.example.com"))
    #expect((mixed.0["trigger"] as? [String: Any])?["if-domain"] as? [String] == ["*example.com"])
    let page = try #require(ContentRules.rule("@@||example.com/allowed-path$document"))
    #expect((page.0["trigger"] as? [String: Any])?["if-top-url"] as? [String] == [ContentRules.urlFilter("||example.com/allowed-path")!])
    let noPing = try #require(ContentRules.rule("/collect$~ping"))
    let kinds = try #require((noPing.0["trigger"] as? [String: Any])?["resource-type"] as? [String])
    #expect(!kinds.contains("raw") && !kinds.contains("ping") && !kinds.contains("other"))
    let endpoint = try NSRegularExpression(pattern: ContentRules.urlFilter("/endpoint^")!)
    for url in ["https://ads.example/endpoint", "https://ads.example/endpoint?x=1", "https://ads.example/endpoint/x"] {
        #expect(endpoint.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil)
    }
    let xhr = try #require(ContentRules.rule("/collect$xmlhttprequest"))
    #expect((xhr.0["trigger"] as? [String: Any])?["resource-type"] as? [String] == ["fetch"])
}

@MainActor
private final class BlockerNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    var requests = Set<String>()
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished = true
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished = true
    }
}


@Test func blocklistDownloadsRequireARealList() {
    let list = "[Adblock Plus 2.0]\n! Title: EasyList\n! Version: 1\n" + String(repeating: "||ads.example^\n", count: 101)
    #expect(ContentRules.downloadedList(Data(list.utf8)) == list)
    #expect(ContentRules.downloadedList(Data("<html>Service unavailable</html>".utf8)) == nil)
    #expect(ContentRules.downloadedList(Data("[Adblock Plus 2.0]\n".utf8)) == nil)
    #expect(ContentRules.downloadedList(Data(repeating: 65, count: 10_000_001)) == nil)
}

/// Across the top, new tabs go at the end, by the + button; down the side, at
/// the top, under New Tab.
@MainActor
@Test func newTabsGoWhereTheirButtonIs() {
    let browser = Browser()
    browser.add(Nerda.Tab(), last: false)
    let first = browser.tabs[0].id
    browser.add(Nerda.Tab(), last: true)
    #expect(browser.tabs.first?.id == first)
    browser.add(Nerda.Tab(), last: false)
    #expect(browser.tabs.map(\.id).firstIndex(of: first) == 1)
}

/// Pages left at the zoom pages open at take a new one, asleep or awake; a
/// page zoomed on its own keeps its zoom.
@MainActor
@Test func pagesFollowTheDefaultZoom() {
    let plain = Nerda.Tab(url: somewhere), zoomed = Nerda.Tab(url: somewhere)
    zoomed.zoom(1)
    let asleep = Nerda.Tab(restoring: Session.Tab(url: somewhere, title: "", state: nil, zoom: 1, pinned: nil, home: nil))
    for tab in [plain, zoomed, asleep] { tab.defaultZoomChanged(from: 1, to: 1.25) }
    #expect(plain.webView.pageZoom == 1.25)
    #expect(zoomed.webView.pageZoom == 1.15)
    #expect(asleep.webView.pageZoom == 1.25)
    for tab in [plain, zoomed, asleep] { tab.silence() }
}

@MainActor @Test func deletingHistoryKeepsPagesVisitedBeforeTheRange() {
    let history = History()
    let old = URL(string: "https://old.example/")!
    let new = URL(string: "https://new.example/")!
    history.visit(old, title: "Old", at: .now.addingTimeInterval(-2 * 60 * 60))
    history.visit(new, title: "New")
    history.remove(since: DeleteRange.hour.since)
    #expect(history.visits.keys.sorted { $0.absoluteString < $1.absoluteString } == [old])
    history.remove(since: DeleteRange.all.since)
    #expect(history.visits.isEmpty)
}

/// Hosts files and `$all` filters, as the malware and server lists write them.
@Test func hostsLinesAndAllFiltersBlockTheirNames() throws {
    let host = try #require(ContentRules.rule("127.0.0.1 ads.example # a comment"))
    #expect(host.0["trigger"] as? [String: Any] != nil && !host.1)
    #expect(((host.0["trigger"] as? [String: Any])?["url-filter"] as? String) == ContentRules.urlFilter("||ads.example^"))
    #expect(ContentRules.rule("0.0.0.0 tracker.example")?.1 == false)
    #expect(ContentRules.rule("127.0.0.1 localhost") == nil)
    #expect(ContentRules.rule("# This hosts file is brought to you by") == nil)
    #expect(ContentRules.rule("||malware.example^$all") != nil)
}

/// More rules than one list takes go in parts, each with every exception.
@Test func manyRulesAreCompiledInParts() throws {
    let text = (0..<5).map { "||ads\($0).example^" }.joined(separator: "\n") + "\n@@||good.example^"
    let parts = try #require(ContentRules.encode(text, partsOf: 12))
    let decoded = try parts.map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]]) }
    let exceptions = decoded[0].count { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" }
    #expect(decoded.allSatisfy { $0.count <= 12 })
    #expect(decoded.allSatisfy { part in part.count { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" } == exceptions })
    #expect(decoded.reduce(0) { $0 + $1.count { ($0["action"] as? [String: String])?["type"] == "block" } } == 5)
}

/// Bookmarks go into folders and out again, and are put where a drop aims,
/// counted as they were before the move; a folder never into itself.
@MainActor
@Test func bookmarksMoveBetweenFoldersButNeverIntoThemselves() {
    let bookmarks = Bookmarks()
    let a = Bookmarks.Item(title: "a", url: somewhere), b = Bookmarks.Item(title: "b", url: somewhere)
    let outer = Bookmarks.Item(title: "outer", children: []), inner = Bookmarks.Item(title: "inner", children: [])
    [a, b, outer].forEach { bookmarks.add($0) }
    bookmarks.add(inner, to: outer.id)

    bookmarks.move(a.id, to: nil, at: 2)  // below b: aimed before it moves
    #expect(bookmarks.items.map(\.title) == ["b", "a", "outer"])
    bookmarks.move(a.id, to: inner.id, at: .max)
    #expect(bookmarks.item(inner.id)?.children?.map(\.id) == [a.id])
    bookmarks.move(outer.id, to: inner.id, at: 0)  // into what is inside it
    #expect(bookmarks.items.map(\.title) == ["b", "outer"])

    // Only open folders show what is in them, each one deeper.
    #expect(bookmarks.rows.map(\.item.title) == ["b", "outer"])
    bookmarks.toggle(outer.id)
    bookmarks.toggle(inner.id)
    #expect(bookmarks.rows.map(\.depth) == [0, 0, 1, 2])

    #expect(bookmarks.remove(outer.id)?.children?.first?.children?.first?.id == a.id)
    #expect(bookmarks.item(a.id) == nil)
}

/// A bookmark opens in a tab of its own, kept out of the list; closed, it
/// stays, and opens again at its address. Taken out of the bookmarks, its
/// tab goes on in the list.
@MainActor
@Test func aBookmarkIsATabThatStays() throws {
    let browser = Browser()
    browser.bookmarks = Bookmarks()
    browser.open(somewhere)
    let tab = try #require(browser.selected)
    browser.bookmark(tab.id)
    let id = try #require(tab.bookmark)
    #expect(browser.bookmarks.item(id)?.url?.host() == "example.com")
    #expect(!browser.tabs.contains(where: Browser.listed))

    browser.close(tab.id)
    #expect(browser.bookmarks.item(id) != nil)
    browser.open(bookmark: id)
    let again = try #require(browser.selected)
    #expect(again.bookmark == id && again.site?.host() == "example.com")
    browser.open(bookmark: id)  // already open: that one, not another
    #expect(browser.tabs.filter { $0.bookmark == id }.count == 1)

    browser.toggleBookmark()  // ⌘D on it
    #expect(browser.bookmarks.items.isEmpty)
    #expect(again.bookmark == nil && Browser.listed(again))
}

/// Chrome, Safari and Firefox export bookmarks as the same old HTML: its
/// folders come in as folders, and what is escaped in it as it was.
@Test func bookmarksComeInFromAnExportedFile() {
    let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com/?a=1&amp;b=2" ADD_DATE="1">Tom &amp; Jerry</A>
                <DT><H3>Empty</H3>
                <DL><p>
                </DL><p>
            </DL><p>
            <DT><A HREF="https://swift.org/">Swift</A>
            <DT><A HREF="javascript:alert(1)">Not a page</A>
        </DL><p>
        """
    let items = Bookmarks.parse(html: html)
    #expect(items.map(\.title) == ["Bookmarks bar", "Swift"])
    #expect(items[0].children?.map(\.title) == ["Tom & Jerry", "Empty"])
    #expect(items[0].children?[0].url == URL(string: "https://example.com/?a=1&b=2"))
    #expect(items[0].children?[1].children == [])
    #expect(Bookmarks.pages(in: items) == 2)
}

/// Responsive Design Mode: a device turned on its side is still that device;
/// a size typed in is a custom one, still with the device's browser.
@MainActor @Test func responsiveSizeKeepsItsDevice() {
    let tab = Tab(), phone = Device.groups[0].devices[1]
    tab.responsive = Responsive(phone)
    tab.resize(width: phone.height, height: phone.width)
    #expect(tab.responsive?.device == phone.name)
    tab.resize(width: 500)
    #expect(tab.responsive?.device == nil)
    #expect(tab.responsive?.agent == Device.iPhoneAgent)
}
