import SwiftUI
import WebKit

/// One browser window: its tabs, newest first, which one is showing, and what
/// is open around them. There is always a tab: with nothing else open, a new
/// one, asking where to go.
@Observable
final class Browser: NSObject {
    private(set) var tabs: [Tab] = [] {
        // However a tab goes, its page goes quiet now, not once the last
        // reference to it is let go, which something may yet hold on to.
        didSet {
            for tab in oldValue where !tabs.contains(where: { $0 === tab }) {
                tab.silence()
                recent.removeAll { $0 === tab }
            }
            sessionChanged()
            Extensions.shared.follow(self)
        }
    }
    /// The open tabs in the order they were on screen, the one on screen
    /// last: closing it goes back down this, as Vivaldi does.
    @ObservationIgnored private(set) var recent: [Tab] = []
    var selectedID: Tab.ID? {
        didSet {
            tabs.first { $0.id == oldValue }?.lastSeen = .now
            if let selected {
                recent.removeAll { $0 === selected }
                recent.append(selected)
            }
            // As in Chrome, going to another tab takes the page out of full screen.
            if selectedID != oldValue { exitPageFullscreen() }
            // Accounts listed under a box of the tab left behind.
            if selectedID != oldValue { passwordChoices = nil }
            if selectedID != oldValue, PictureInPicture.isOn {
                tabs.first { $0.id == oldValue }?.page?.evaluateJavaScript(PictureInPicture.enter)
                selected?.page?.evaluateJavaScript(PictureInPicture.exit)
            }
            if selectedID != oldValue { Extensions.shared.activated(self, from: oldValue) }
            sessionChanged()
        }
    }
    var sidebarOpen = true
    /// The tab switcher (⌘⇧A): the open tabs, and anywhere else to go.
    var commandBarOpen = false {
        didSet { if commandBarOpen { exitPageFullscreen() } }
    }
    /// Counts asks for the switcher or the address, so one with it already
    /// open still puts the keyboard in it.
    var commandBarRequests = 0
    /// The same, for the field on a new tab (⌘T).
    var newTabRequests = 0
    /// Delete browsing data is open over the history page (Clear History…).
    var clearingHistory = false
    /// The address bar's address is being typed over (⌘L), to take the tab on
    /// screen somewhere else.
    var editingAddress = false
    /// An incognito window hidden behind its lock, until Touch ID or the
    /// Mac's password opens it (see `Windows.lock`).
    var locked = false
    /// The tab whose page shows one of its elements (a video) over the whole
    /// window, as it asked to. Always the one on screen.
    private(set) var fullscreenTab: Tab.ID?
    /// This session's downloads, newest first.
    private(set) var downloads: [Download] = []
    /// Find in page (⌘F): the bar, what it looks for, and whether the last look found it.
    var findBarOpen = false
    var findQuery = ""
    private(set) var findMissing = false
    /// Counts ⌘Fs, so one with the bar already open still puts the keyboard in it.
    var findRequests = 0
    /// The saved accounts listed under the sign-in box the caret is in, and a
    /// sign-in's password offered to keep (see Passwords).
    var passwordChoices: PasswordChoices?
    var passwordOffer: PasswordOffer?
    /// Counts what changes the list, so an answer from the keychain that
    /// comes after the caret has moved on is let go.
    @ObservationIgnored var choicesAsked = 0
    /// Where passwords are kept; tests give theirs a store of its own.
    @ObservationIgnored var vault = Vault.shared
    /// The same for bookmarks.
    @ObservationIgnored var bookmarks = Bookmarks.shared

    /// How long a tab can go unseen before it sleeps.
    // ponytail: fixed; a setting once there are settings. Edge's default is 2 hours,
    // this is shorter because staying light is the point.
    static let sleepAfter: TimeInterval = 30 * 60
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?
    /// The address last loaded again for a redirect WebKit lost, so it is only tried once.
    @ObservationIgnored private var retried: URL?
    /// Where the tabs are saved as they change (see Session); nil keeps them
    /// to this run, as in tests, and while the window is closed.
    @ObservationIgnored var sessionFile: URL?
    @ObservationIgnored var pendingSave: Task<Void, Never>?
    @ObservationIgnored var savedSession: Data?
    @ObservationIgnored private var sessionTimer: Timer?
    /// The window it is shown in, which closing its last tab closes; none in tests.
    @ObservationIgnored weak var window: NSWindow?

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    /// Where its pages keep cookies, cache and site data: the one on disk, or
    /// for an incognito window, one in memory, gone with the window.
    let dataStore: WKWebsiteDataStore
    /// An incognito window's: no history kept, no session saved, nothing on disk.
    var isPrivate: Bool { !dataStore.isPersistent }
    /// What its fields suggest from: your history, or in incognito, nothing of it.
    var history: History { isPrivate ? History.empty : .shared }

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init()
        // Checked each minute, loosely, so the system can fold it in with other wake-ups.
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs(unseenFor: Self.sleepAfter) }
        }
        sleepTimer?.tolerance = 15
        // What changes without telling (scrolling, a page changing its own
        // address) is saved every few seconds, and only if it did change.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        sessionTimer?.tolerance = 3
        // When the Mac runs short of memory, every tab out of sight sleeps at once.
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sleepIdleTabs(unseenFor: 0) }
        }
        memoryPressure?.activate()
    }

    /// An incognito window's browser goes with its window.
    isolated deinit {
        sleepTimer?.invalidate()
        sessionTimer?.invalidate()
        memoryPressure?.cancel()
    }

    /// Tabs out of sight at least this long, and not busy (playing, on a call),
    /// sleep. Pinned ones never do: being always ready is what they are for.
    func sleepIdleTabs(unseenFor age: TimeInterval) {
        let cutoff = Date.now.addingTimeInterval(-age)
        for tab in tabs where tab.id != selectedID && !tab.isPinned && !tab.isAsleep && tab.lastSeen <= cutoff {
            Task {
                // Asked of the page, so it may have come on screen in the meantime.
                guard await !tab.isBusy(), tab.id != selectedID else { return }
                let look = await tab.snapshot()
                if tab.id != selectedID { tab.sleep(keeping: look) }
            }
        }
    }

    /// A tab for `url`, on screen, or for a link opened in the background
    /// (⌘-click), behind the one that is.
    @discardableResult
    func open(_ url: URL, inBackground: Bool = false) -> Tab {
        let tab = Tab()
        add(tab, inBackground: inBackground)
        tab.go(to: url)
        return tab
    }

    /// Pinned tabs come first, in their own order; the rest follow, newest
    /// first, under the sidebar's New Tab, or across the top, newest `last`,
    /// by its + button.
    func add(_ tab: Tab, inBackground: Bool = false, last: Bool = TabStyle.current == .horizontal) {
        tab.dataStore = dataStore
        tab.delegate = self
        tabs.insert(tab, at: tab.isPinned ? 0 : last ? tabs.count : pinnedCount)
        if !inBackground { selectedID = tab.id }
    }

    var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// Pinned, a tab goes to the end of the tiles; unpinned, to the top of the list.
    func setPinned(_ pinned: Bool, _ id: Tab.ID) {
        guard tabs.first(where: { $0.id == id })?.isPinned != pinned else { return }
        move(id, pinned: pinned, to: pinned ? .max : 0)
    }

    /// The tab on screen, at once: a press and the click it ends in both ask.
    func select(_ id: Tab.ID) {
        if selectedID != id { selectedID = id }
    }

    /// A tab's own name; an empty one gives it back its page's title.
    func rename(_ id: Tab.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs.first { $0.id == id }?.name = name.isEmpty ? nil : name
        sessionChanged()
    }

    /// The keyboard back on the page on screen, once something of ours
    /// that had it (a field) is done with it.
    func focusPage() {
        if let page = selected?.page { page.window?.makeFirstResponder(page) }
    }

    /// Puts a tab at `position` among the pinned tabs, or among the rest
    /// that are `among` them (the sidebar's list has no bookmarks' tabs),
    /// pinning or unpinning it on the way; past the end is the end.
    func move(_ id: Tab.ID, pinned: Bool, to position: Int, among: (Tab) -> Bool = { _ in true }) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // A new tab, or the settings, has no site to pin; a bookmark's tab has its place.
        guard !pinned || tabs[index].hasPage && tabs[index].bookmark == nil else { return }
        // Moved in one change: `tabs` taking it out on its own would silence its page.
        var moved = tabs
        let tab = moved.remove(at: index)
        let pins = moved.prefix { $0.isPinned }.count
        let places = moved.indices.dropFirst(pins).filter { among(moved[$0]) }
        let position = max(position, 0)
        moved.insert(tab, at: pinned ? min(position, pins)
                     : position < places.count ? places[position] : places.last.map { $0 + 1 } ?? pins)
        // Called on every step of a drag: nothing to tell when nothing moved.
        guard tab.isPinned != pinned || !moved.elementsEqual(tabs, by: ===) else { return }
        if tab.isPinned != pinned { tab.home = pinned ? tab.site : nil }
        tab.isPinned = pinned
        tabs = moved
    }

    /// Closing the tab on screen goes back to the tab on screen before it,
    /// wherever that is in the list: the page that opened a popup or a new
    /// tab, unless you went elsewhere since. With none seen before it (just
    /// after launch), to the one that slides into its place, or to the one
    /// above when there is none below.
    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if passwordOffer?.tab == id { passwordOffer = nil }
        if selectedID == id {
            selectedID = recent.last?.id ?? (tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id)
        }
        // With nothing left, the window goes, as in other browsers: an
        // incognito one, and incognito with it. Without a window, a new tab.
        if tabs.isEmpty {
            if let window { window.close() } else { add(Tab()) }
        }
    }

    /// Closing the window closes its tabs, as Safari does: nothing keeps
    /// playing, or holding memory, behind a window that is gone. They are
    /// still saved, as Chrome keeps its last window: they come back with the
    /// window, or at the next launch.
    func closeAll() {
        saveSession()
        sessionFile = nil
        tabs.removeAll()
        selectedID = nil
        commandBarOpen = false
    }

    /// The sidebar's list: the tabs not pinned, nor a bookmark's.
    static let listed: (Tab) -> Bool = { !$0.isPinned && $0.bookmark == nil }

    /// The tabs in the order they are shown: down the side, the pinned, the
    /// bookmarks' open ones, then the list; across the top, as they are.
    var inTurn: [Tab] {
        guard TabStyle.current == .vertical, tabs.contains(where: { $0.bookmark != nil }) else { return tabs }
        let open = Dictionary(tabs.compactMap { tab in tab.bookmark.map { ($0, tab) } }) { first, _ in first }
        return tabs.filter(\.isPinned) + bookmarks.all.compactMap { open[$0.id] } + tabs.filter(Self.listed)
    }

    /// ⌘1 to ⌘8, top down; ⌘9 is always the last, as in every browser.
    func selectTab(number: Int) {
        let tabs = inTurn
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { selectedID = tabs[index].id }
    }

    /// ⌃Tab and ⌃⇧Tab: the next tab down, or up, round from the end to the start.
    func selectTab(after step: Int) {
        let tabs = inTurn
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = tabs[(index + step + tabs.count) % tabs.count].id
    }

    /// The next match on the page, or the one before; round to the start past the end.
    func find(backwards: Bool = false) {
        guard let page = selected?.page, !findQuery.isEmpty else { return findMissing = false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        let query = findQuery
        Task {
            let found = (try? await page.find(query, configuration: configuration))?.matchFound ?? false
            if query == findQuery { findMissing = !found }
        }
    }

    /// A page going full screen, or coming back. Only the page on screen, and
    /// only straight after a click or key press: the page checks that too, but
    /// it could be got round there. The pointer only passing by is not one.
    func page(_ page: WKWebView, wantsFullscreen: Bool) {
        guard let tab = tab(for: page) else { return }
        guard wantsFullscreen else {
            if fullscreenTab == tab.id { fullscreenTab = nil }
            return
        }
        let sinceInput = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .keyDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        guard tab.id == selectedID, !commandBarOpen, sinceInput < 1 else {
            page.evaluateJavaScript(Fullscreen.exit)
            return
        }
        fullscreenTab = tab.id
    }

    func exitPageFullscreen() {
        guard let id = fullscreenTab else { return }
        fullscreenTab = nil
        tabs.first { $0.id == id }?.page?.evaluateJavaScript(Fullscreen.exit)
    }

    /// Those done, or only those started from `since` on (Delete browsing data).
    func clearDownloads(since: Date = .distantPast) {
        downloads.removeAll { $0.state != .running && $0.started >= since }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.page === webView }
    }
}

/// Windows a page opens, from links with target=_blank to sign-in popups,
/// open as tabs; one that closes itself closes its tab. A page's alerts, and
/// its file pickers, come up as sheets over it.
extension Browser: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if (webView as? SwipingWebView)?.takeIncognitoAsk() == true, let url = action.request.url {
            // Only the web: loaded from here, a page's link to a file on this
            // Mac (file:) would open where a page itself may not take you.
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { Windows.openIncognito(url) }
            return nil
        }
        let tab = Tab(configuration: configuration, opener: tab(for: webView))
        withAnimation(.slide) { add(tab) }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        withAnimation(.slide) { close(tab.id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(Self.says(frame), message, over: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(Self.says(frame), message, over: webView, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 280
        let answer = await ask(Self.says(frame), prompt, over: webView, buttons: ["OK", "Cancel"], field: field)
        return answer == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = await window(showing: webView) else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private static func says(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page says" : "\(host) says"
    }

    /// A sheet over the page, once its tab is on screen: a question should
    /// show what it is about.
    private func ask(_ title: String, _ message: String, over webView: WKWebView,
                     buttons: [String] = ["OK"], field: NSTextField? = nil) async -> NSApplication.ModalResponse {
        guard let window = await window(showing: webView) else { return .cancel }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await alert.beginSheetModal(for: window)
    }

    /// The page's own window, once its tab is the one on screen. A page out of
    /// sight waits for you to go to it, as in Chrome, rather than bring its
    /// tab forward: an alert would otherwise take you away from the tab you
    /// are on, to whatever the page wanted to show. nil if the tab goes, or
    /// sleeps, meanwhile.
    // ponytail: looked at five times a second, only while a tab out of sight has something to ask.
    private func window(showing webView: WKWebView) async -> NSWindow? {
        guard let tab = tab(for: webView) else { return nil }
        while tab.id != selectedID || locked {
            try? await Task.sleep(for: .milliseconds(200))
            guard tab.page === webView, tabs.contains(where: { $0 === tab }) else { return nil }
        }
        return webView.window ?? window
    }
}

extension Browser: WKNavigationDelegate {
    /// Each load, a frame's too, runs the page's scripts unless its tab has
    /// them off (Develop › Disable JavaScript).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = tab(for: webView)?.javaScriptOff != true
        return (await policy(for: action, in: webView), preferences)
    }

    private func policy(for action: WKNavigationAction, in webView: WKWebView) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.shouldPerformDownload { return .download }

        // An extension's sign-in coming back: the address is its answer,
        // handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView) { return .cancel }
        // An extension's page sending its tab to a website: the tab makes
        // itself a page for the web (see Tab.go).
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), action.targetFrame?.isMainFrame ?? true,
           let tab = tab(for: webView), tab.madeFor != nil {
            Task { tab.go(to: url) }
            return .cancel
        }
        // 0.0.0.0, the address local servers print as where they listen, is
        // refused by WebKit; it means this Mac, so 127.0.0.1 is opened instead.
        if action.targetFrame?.isMainFrame ?? true, url.host() == "0.0.0.0",
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.host = "127.0.0.1"
            if let local = parts.url { webView.load(URLRequest(url: local)) }
            return .cancel
        }

        // mailto:, tel:, zoommtg: and the like belong to other apps, and only
        // with a yes: a page could otherwise start any app it names.
        if !Self.pageSchemes.contains(url.scheme?.lowercased() ?? "") {
            guard action.targetFrame?.isMainFrame ?? true,
                  let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return .cancel }
            let name = FileManager.default.displayName(atPath: app.path).replacing(".app", with: "")
            let answer = await ask("Open “\(name)”?", "This page wants to open \(name).", over: webView,
                                   buttons: ["Open", "Cancel"])
            if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            return .cancel
        }

        // ⌘-click: a tab of its own, behind this one.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            withAnimation(.slide) { open(url, inBackground: true) }
            return .cancel
        }
        // A middle click (the buttons as a mask: 4 is the middle one) is opened
        // behind by Tab.middleClick, as not every WebKit asks here for it. This
        // WebKit would also take the page itself there.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 { return .cancel }
        return .allow
    }

    private static let pageSchemes: Set = ["http", "https", "file", "about", "data", "blob", "javascript", ViewSource.scheme, Extensions.scheme]

    /// What a page can't show (a zip), or is told to save (an attachment), is downloaded.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // A WebKit bug: a redirect onto a page its service worker serves
        // (youtube.com to www.youtube.com, once visited) comes with no response
        // at all, which would load blank or be saved as a file. Going to the new
        // address directly works, so that is done instead, once.
        if response.response.url == nil {
            guard response.isForMainFrame, let url = webView.url, url != retried else { return .cancel }
            retried = url
            Task { webView.load(URLRequest(url: url)) }
            return .cancel
        }
        let http = response.response as? HTTPURLResponse
        // A redirect is followed, whatever it says it is: youtube.com sends its
        // move to www.youtube.com as application/binary, which would be saved.
        if let status = http?.statusCode, (300..<400).contains(status) { return .allow }
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return response.canShowMIMEType && !disposition.lowercased().hasPrefix("attachment") ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
        // A link that opened a new tab only to download leaves nothing to show in it.
        if webView.backForwardList.currentItem == nil, let tab = tab(for: webView) {
            withAnimation(.slide) { close(tab.id) }
        }
    }

    /// A download an extension asked for (chrome.downloads), through the
    /// page on screen, or any page awake; false with none.
    func download(_ url: URL) async -> Bool {
        guard let page = selected?.page ?? tabs.lazy.compactMap(\.page).first else { return false }
        track(await page.startDownload(using: URLRequest(url: url)))
        return true
    }

    private func track(_ download: WKDownload) {
        download.delegate = self
        withAnimation(.slide) { downloads.insert(Download(download), at: 0) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        retried = nil
        tab(for: webView)?.pageDidCommit()
        tab(for: webView)?.failure = nil
        tab(for: webView)?.recordVisit()
        if let tab = tab(for: webView) { hideChoices(on: tab) }
        // A new document has nothing on show.
        if let tab = tab(for: webView), fullscreenTab == tab.id { fullscreenTab = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab(for: webView)?.pageDidLoad()
        if let tab = tab(for: webView) { signInLanded(on: tab) }
        WebStore.tell(webView)
        sessionChanged()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        // Stopped, overtaken by another load, or turned into a download: nothing went wrong.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        tab(for: webView)?.failure = (url, error.localizedDescription)
    }

    /// A certificate the Mac doesn't trust is refused, as ever, except on this
    /// Mac itself: a local server with a certificate of its own, as developers
    /// run, opens, as Chrome and Search let it. Nothing can be in between there.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              Self.isThisMac(space.host) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// localhost and its names, and the loopback addresses (127.x.x.x, ::1).
    nonisolated static func isThisMac(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
            || (parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil })
    }

    /// The page's process died (out of memory, or a WebKit bug): it would stay
    /// blank, so it is loaded again, as Safari does. One out of sight sleeps
    /// instead, and loads when it is next shown: reloading it now would only
    /// add to the memory it may have died for. A page that dies again within
    /// a minute would only keep reloading, and says so instead; ⌘R tries again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if fullscreenTab == tab.id { fullscreenTab = nil }
        let again = tab.crashed.map { Date.now.timeIntervalSince($0) < 60 } ?? false
        tab.crashed = .now
        if again, let url = webView.url ?? tab.site {
            tab.failure = (url, "The page crashed each time it was opened.")
        } else if tab.id == selectedID {
            webView.reload()
        } else {
            tab.sleep()
        }
    }
}

/// Downloads go to ~/Downloads under the name the site gives, numbered when
/// that is taken, and bounce the Downloads stack in the Dock when done.
extension Browser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let destination = Downloads.destination(for: suggestedFilename, in: .downloadsDirectory)
        item(for: download)?.file = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.finish()
        if let file = item.file {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        item(for: download)?.fail()
    }

    private func item(for download: WKDownload) -> Download? {
        downloads.first { $0.task === download }
    }
}

/// What was typed, as somewhere to go: an address as it is, anything else
/// as a search, on the search engine chosen in the settings.
nonisolated enum Address {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") { return URL(string: text) }
        // A file on this Mac, by its path, as Chrome opens one.
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = NSString(string: text).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }

        guard !text.contains(" "), let typed = URL(string: "http://" + text),
              let host = typed.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              host.contains(".") || host.contains(":") || typed.port != nil || Browser.isThisMac(host)
        else { return search(text) }
        // Somewhere local (a server on this Mac, a router, a machine on the
        // network), or on a port of its own, answers http: https:// there
        // fails, as it did for 127.0.0.1:5173. The rest of the web is https,
        // as in Chrome.
        let plain = typed.port.map { $0 != 443 } ?? isLocal(host)
        return plain ? typed : URL(string: "https://" + text)
    }

    /// An IP address, or a name only a local network has: localhost, one
    /// word, or a name under a suffix kept for local use (.local, .test, …).
    static func isLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return host.contains(":") || !host.contains(".") || Browser.isThisMac(host)
            || parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
            || ["local", "localhost", "test", "internal", "lan", "home.arpa"].contains { host.hasSuffix("." + $0) }
    }

    static func search(_ text: String) -> URL? {
        SearchEngine.current.search(text)
    }

    /// What the search engine thinks is being searched for, as it would suggest
    /// under its own field; nothing when it can't be reached.
    static func suggestions(for text: String) async -> [String] {
        // ["query", ["suggestion", …], …]
        guard let request = SearchEngine.current.guesses(text),
              let (data, _) = try? await URLSession.shared.data(from: request),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [Any],
              reply.count > 1, let suggestions = reply[1] as? [String]
        else { return [] }
        return suggestions
    }
}
