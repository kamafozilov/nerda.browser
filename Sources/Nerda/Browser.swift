import SecurityInterface
import SwiftUI
@preconcurrency import Translation
import WebKit

/// One browser window: its tabs, newest first, which one is showing, and what
/// is open around them. There is always a tab: with nothing else open, a new
/// one, asking where to go.
@Observable
final class Browser: NSObject {
    private(set) var tabs: [Tab] = [] {
        // However a tab goes, its page goes quiet now, not once the last
        // reference to it is let go, which something may yet hold on to.
        // By identity, in a set: with hundreds of tabs, looking each one up in
        // the list took longer than the change itself.
        didSet {
            let open = Set(tabs.map(ObjectIdentifier.init))
            for tab in oldValue where !open.contains(ObjectIdentifier(tab)) { tab.silence() }
            recent.removeAll { !open.contains(ObjectIdentifier($0)) }
            if selected.map({ !open.contains(ObjectIdentifier($0)) }) ?? (selectedID != nil) { findSelected() }
            sessionChanged()
            // Only once they have started, after the window: made any sooner
            // for this, they would hold up the window.
            if Extensions.started { Extensions.shared.follow(self) }
        }
    }
    /// The open tabs in the order they were on screen, the one on screen
    /// last: closing it goes back down this, as Vivaldi does.
    @ObservationIgnored private(set) var recent: [Tab] = []
    var selectedID: Tab.ID? {
        didSet {
            if selected?.id != selectedID { findSelected() }
            if let left = tabs.first(where: { $0.id == oldValue }) {
                left.lastSeen = .now
                left.pageMoved()
            }
            if let selected {
                recent.removeAll { $0 === selected }
                recent.append(selected)
            }
            // As in Chrome, going to another tab takes the page out of full screen.
            if selectedID != oldValue { exitPageFullscreen() }
            // Accounts listed under a box of the tab left behind.
            if selectedID != oldValue { passwordChoices = nil }
            if selectedID != oldValue, PictureInPicture.isOn {
                // A muted tab's video has no sound to keep hearing.
                tabs.first { $0.id == oldValue && !$0.isMuted }?.page?.evaluateJavaScript(PictureInPicture.enter)
                selected?.page?.evaluateJavaScript(PictureInPicture.exit)
            }
            if selectedID != oldValue, Extensions.started { Extensions.shared.activated(self, from: oldValue) }
            // Its page may be the one to translate now.
            if selectedID != oldValue { translator.nudge() }
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
    /// Where this window's downloads go instead of `Downloads.folder` (tests).
    @ObservationIgnored var downloadFolder: URL?
    var recentlyClosed: [Session.ClosedTab] = []
    @ObservationIgnored private var closing: Set<Tab.ID> = []
    let siteSettings: SiteSettings
    /// A site's question waiting for an answer (`askPermission`).
    var permissionRequest: PermissionRequest?
    /// Find in page (⌘F): the bar, what it looks for, and where the last look got to.
    var findBarOpen = false
    var findQuery = ""
    /// The page last looked in, whose matches are still lit.
    @ObservationIgnored private weak var foundOn: WKWebView?
    /// Nil before a look, and where only WebKit's own find works (a PDF),
    /// which counts nothing, once it has found one.
    private(set) var findMatches: Find.Matches?
    @ObservationIgnored private var findTyping: Task<Void, Never>?
    /// Find's options (the magnifying glass's menu), kept for every window.
    static let findMatchCaseKey = "findMatchCase"
    static let findWholeWordsKey = "findWholeWords"
    /// Counts ⌘Fs, so one with the bar already open still puts the keyboard in it.
    var findRequests = 0
    /// The saved accounts listed under the sign-in box the caret is in, and a
    /// sign-in's password offered to keep (see Passwords).
    var passwordChoices: PasswordChoices?
    var passwordOffer: PasswordOffer?
    /// Addresses and cards a form sent, offered to keep one at a time (see AutoFill).
    var autofillOffers: [AutoFillOffer] = []
    /// Counts what changes the list, so an answer from the keychain that
    /// comes after the caret has moved on is let go.
    @ObservationIgnored var choicesAsked = 0
    /// Where passwords are kept; tests give theirs a store of its own.
    @ObservationIgnored var vault = Vault.shared
    /// The same for bookmarks.
    @ObservationIgnored var bookmarks = Bookmarks.shared
    /// Translates the tab on screen, while it is translated (`translationTask`).
    @ObservationIgnored let translator = Translator()

    /// A tab taking more than `heavy` sleeps after this long unseen, pinned
    /// or not. Most pages take 100–400 MB; x.com and Gmail kept 650–750 MB
    /// each, pinned and never seen, and a WebGL site GBs. Woken, it loads
    /// again in a second or two.
    static let heavyAfter: TimeInterval = 10 * 60
    static let heavy: UInt64 = 500 << 20
    /// Between one pinned tab loading at launch and the next (Session).
    static let pinLoadGap: Duration = .milliseconds(500)
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?
    /// The address last loaded again for a redirect WebKit lost, so it is only tried once.
    @ObservationIgnored private var retried: URL?
    /// The sites left to http this session; an incognito window's its own.
    @ObservationIgnored var httpsUpgrade = HTTPSUpgrade()
    /// The certificate chosen for each host this session, sent from then on
    /// without asking, as in Safari; an incognito window's its own.
    @ObservationIgnored var chosenCertificates: [String: SecIdentity] = [:]
    /// The frames whose navigation under way a click or a key in the page
    /// started, by WebKit's handle for each (see `mayDownload`).
    @ObservationIgnored private var clickedFrames: Set<NSObject> = []
    /// Where the tabs are saved as they change (see Session); nil keeps them
    /// to this run, as in tests, and while the window is closed.
    @ObservationIgnored var sessionFile: URL?
    @ObservationIgnored var pendingSave: Task<Void, Never>?
    @ObservationIgnored var savedSession: Session?
    @ObservationIgnored private var sessionTimer: Timer?
    /// The window it is shown in, which closing its last tab closes; none in tests.
    @ObservationIgnored weak var window: NSWindow?

    /// The tab on screen, kept rather than looked up: what shows it then
    /// draws again when it changes, not on every change to the list, as
    /// each step of a drag in the sidebar is.
    private(set) var selected: Tab?

    private func findSelected() {
        let found = selectedID.flatMap { id in tabs.first { $0.id == id } }
        if found !== selected { selected = found }
    }

    /// The languages the tab on screen is translated between, for the
    /// window's translation session; none while it isn't.
    var translationConfiguration: TranslationSession.Configuration? {
        selected?.translation.map {
            .init(source: Locale.Language(identifier: $0.source), target: Locale.Language(identifier: $0.target))
        }
    }

    /// Where its pages keep cookies, cache and site data: the one on disk, or
    /// for an incognito window, one in memory, gone with the window.
    let dataStore: WKWebsiteDataStore
    /// An incognito window's: no history kept, no session saved, nothing on disk.
    var isPrivate: Bool { !dataStore.isPersistent }
    /// What its fields suggest from: your history, or in incognito, nothing of it.
    var history: History { isPrivate ? History.empty : .shared }

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        siteSettings = dataStore.isPersistent ? .shared : SiteSettings(defaults: nil)
        super.init()
        // Checked each minute, loosely, so the system can fold it in with other wake-ups.
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let after = TabSleep.current.interval { self?.sleepIdleTabs(unseenFor: after) }
                self?.sleepIdleTabs(unseenFor: Self.heavyAfter, pinsToo: true, over: Self.heavy)
            }
        }
        sleepTimer?.tolerance = 15
        // What changes without telling (the page on screen scrolled, a page
        // changing its own address) is saved every few seconds, and only if it
        // did change. Not while another app is in front: it was saved as Nerda
        // went behind.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp?.isActive == true { self?.saveSession(waiting: false) } }
        }
        sessionTimer?.tolerance = 3
        // When the Mac runs short of memory, every tab out of sight sleeps at
        // once; when it runs out, as in Safari, pinned ones too.
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                let critical = self?.memoryPressure?.data.contains(.critical) == true
                self?.sleepIdleTabs(unseenFor: 0, pinsToo: critical)
            }
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
    /// sleep; of those, only the ones taking more than `size`, if given.
    /// Pinned ones only with `pinsToo`: being always ready is what they are for.
    func sleepIdleTabs(unseenFor age: TimeInterval, pinsToo: Bool = false, over size: UInt64 = 0) {
        let cutoff = Date.now.addingTimeInterval(-age)
        for tab in tabs where tab.id != selectedID && (pinsToo || !tab.isPinned) && !tab.isAsleep
            && tab.lastSeen <= cutoff && (size == 0 || (tab.memory ?? 0) > size) {
            Task {
                // Asked of the page, so it may have come on screen in the meantime.
                guard await !tab.isBusy(), tab.id != selectedID else { return }
                let look = await tab.snapshot()
                if tab.id != selectedID, !tab.hasUnsavedWork { tab.sleep(keeping: look) }
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

    /// Settings › Tabs › Load background tabs when shown. Off, as in Safari
    /// and Chrome, which load them at once.
    static let waitsKey = "backgroundTabsWait"
    static var backgroundTabsWait: Bool { UserDefaults.standard.bool(forKey: waitsKey) }

    /// A link opened behind the page by hand: ⌘-click, the middle button,
    /// Open Link in New Tab. `waiting`, it keeps its address and loads
    /// nothing until it is shown, as a tab from the last run does.
    @discardableResult
    func openBehind(_ url: URL, waiting: Bool = Browser.backgroundTabsWait) -> Tab {
        guard waiting else { return open(url, inBackground: true) }
        // A title known from a visit before; otherwise the site's name.
        let tab = Tab(waitingFor: url, title: history.visits[url]?.title ?? "")
        add(tab, inBackground: true)
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

    /// Several behind the one on screen, above the rest, in their own order,
    /// in one change: one by one, restoring hundreds of tabs took seconds.
    func add(_ new: [Tab]) {
        for tab in new {
            tab.dataStore = dataStore
            tab.delegate = self
        }
        let pins = pinnedCount
        tabs = new.filter(\.isPinned) + tabs.prefix(pins) + new.filter { !$0.isPinned } + tabs.dropFirst(pins)
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

    /// The tab's speaker, Mute Tab and Unmute Tab: its sound off, or back on.
    func toggleMute(_ id: Tab.ID) {
        tabs.first { $0.id == id }?.isMuted.toggle()
    }

    /// The keyboard back on the page on screen, once something of ours
    /// that had it (a field) is done with it.
    func focusPage() {
        if let page = selected.flatMap({ $0.reader ?? $0.page }) { page.window?.makeFirstResponder(page) }
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
    func close(_ id: Tab.ID, discarding: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.hasUnsavedWork, !discarding {
            guard let page = tab.page, closing.insert(id).inserted else { return }
            // The question waits for its tab to be on screen (`ask`), as
            // Chrome shows the tab that asks.
            select(id)
            Task {
                defer { closing.remove(id) }
                if await confirmDiscarding(on: page) { close(id, discarding: true) }
            }
            return
        }
        if !isPrivate, let saved = tab.saved, saved.url != nil {
            recentlyClosed.append(Session.ClosedTab(tab: saved, index: index))
            recentlyClosed = Array(recentlyClosed.suffix(25))
        }
        tabs.remove(at: index)
        if passwordOffer?.tab == id { passwordOffer = nil }
        autofillOffers.removeAll { $0.tab == id }
        if selectedID == id {
            selectedID = recent.last?.id ?? (tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id)
        }
        // With nothing left, the window goes, as in other browsers: an
        // incognito one, and incognito with it. Without a window, a new tab.
        if tabs.isEmpty {
            if downloads.contains(where: \.needsSession) { add(Tab()) }
            else if let window { window.close() }
            else { add(Tab()) }
        }
    }

    func reopenClosedTab(_ id: Session.ClosedTab.ID? = nil) {
        guard !isPrivate, let index = id.flatMap({ wanted in recentlyClosed.firstIndex { $0.id == wanted } })
            ?? (id == nil ? recentlyClosed.indices.last : nil) else { return }
        let closed = recentlyClosed.remove(at: index)
        if let bookmark = closed.tab.bookmark, let existing = tab(of: bookmark) {
            select(existing.id)
        } else {
            let tab = Tab(restoring: closed.tab)
            if tab.bookmark.map({ bookmarks.item($0) == nil }) == true { tab.bookmark = nil }
            tab.dataStore = dataStore
            tab.delegate = self
            let position = tab.isPinned ? min(max(closed.index, 0), pinnedCount)
                : min(max(closed.index, pinnedCount), tabs.count)
            tabs.insert(tab, at: position)
            selectedID = tab.id
        }
        sessionChanged()
    }

    func confirmDiscarding(on page: WKWebView) async -> Bool {
        await ask("Leave this page?", "Changes you made may not be saved.", over: page,
                  buttons: ["Stay", "Leave"]) == .alertSecondButtonReturn
    }

    /// Closing the window closes its tabs, as Safari does: nothing keeps
    /// playing, or holding memory, behind a window that is gone. They are
    /// still saved, as Chrome keeps its last window: they come back with the
    /// window, or at the next launch. A password or card offered to keep
    /// goes too, rather than stay in memory with no window to show it.
    func closeAll() {
        saveSession()
        sessionFile = nil
        for download in downloads where download.needsSession { download.cancel() }
        tabs.removeAll()
        selectedID = nil
        commandBarOpen = false
        passwordChoices = nil
        passwordOffer = nil
        autofillOffers = []
    }

    /// The sidebar's list: the tabs not pinned, nor a bookmark's.
    static let listed: (Tab) -> Bool = { !$0.isPinned && $0.bookmark == nil }

    /// The tabs in the order they are shown: down the side, the pinned, the
    /// bookmarks' open ones, then the list; across the top, as they are.
    var inTurn: [Tab] {
        guard TabStyle.current == .vertical, tabs.contains(where: { $0.bookmark != nil }) else { return tabs }
        let open = Dictionary(tabs.compactMap { tab in tab.bookmark.map { ($0, tab) } }) { first, _ in first }
        var marked: [Tab] = []
        Bookmarks.inOrder(open, in: bookmarks.items, into: &marked)
        return tabs.filter(\.isPinned) + marked + tabs.filter(Self.listed)
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

    /// The next match on the page, or the one before; round to the start past
    /// the end. A query not yet looked for starts at the first.
    func find(backwards: Bool = false) { find(step: backwards ? -1 : 1) }

    /// Looks again once typing stops for a moment (the query, or an option),
    /// so a long page isn't read for every letter. The same query typed back
    /// stays on its match.
    func findTyped() {
        findTyping?.cancel()
        findTyping = Task {
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled { find(step: 0) }
        }
    }

    private func find(step: Int) {
        findTyping?.cancel()
        // Reader's article, while it shows.
        guard let page = selected.flatMap({ $0.reader ?? $0.page }), !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return clearFound() }
        if foundOn !== page { clearFound() }
        foundOn = page
        let query = findQuery
        let matchCase = UserDefaults.standard.bool(forKey: Self.findMatchCaseKey)
        let wholeWords = UserDefaults.standard.bool(forKey: Self.findWholeWordsKey)
        Task {
            var matches = await Find.look(for: query, matchCase: matchCase, wholeWords: wholeWords, step: step, on: page)
            if matches == nil {
                // ponytail: a PDF knows no whole words.
                let configuration = WKFindConfiguration()
                configuration.backwards = step < 0
                configuration.caseSensitive = matchCase
                let found = (try? await page.find(query, configuration: configuration))?.matchFound ?? false
                matches = found ? nil : Find.Matches(index: 0, count: 0, more: false)
            }
            if query == findQuery, foundOn === page { findMatches = matches }
        }
    }

    /// The matches lit, and the one selected, go with the bar, the query or
    /// the tab.
    func clearFound() {
        findTyping?.cancel()
        if let foundOn { Find.clear(on: foundOn) }
        foundOn = nil
        findMatches = nil
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
        downloads.removeAll { item in
            guard item.state != .running, item.state != .paused, item.started >= since else { return false }
            if item.state != .finished { item.cancel() }
            return true
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.page === webView }
    }
}

/// Windows a page opens, from links with target=_blank to sign-in popups,
/// open as tabs; one that closes itself closes its tab. A page's alerts, and
/// its file pickers, come up as sheets over it.
extension Browser: WKUIDelegate {
    // WebKit's beforeunload delegate on the supported macOS versions is SPI.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func beforeUnload(_ page: WKWebView, message: String, frame: WKFrameInfo,
                      completionHandler: @escaping (Bool) -> Void) {
        if tab(for: page)?.departureApproved == true { completionHandler(true); return }
        Task { completionHandler(await confirmDiscarding(on: page)) }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let ask = (webView as? SwipingWebView)?.takeLinkAsk()
        if ask == .incognito, let url = action.request.url {
            // Only the web: loaded from here, a page's link to a file on this
            // Mac (file:) would open where a page itself may not take you.
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { Windows.openIncognito(url) }
            return nil
        }
        let opener = tab(for: webView)
        // A window opened by the page itself, on load or on a timer, would
        // take you away to it: only one from a click or a key opens, unless
        // the site may open them all. The rest are kept for the address bar
        // to tell of and open after all, as Safari's Block and Notify. An
        // extension's pages open theirs as they always have, and so does
        // a link opened from its right-click menu.
        if ask == nil, opener?.madeFor == nil, !siteSettings.options(for: opener?.site).allowsPopups, !Self.clicked(action) {
            if let opener {
                opener.blockedPopups = Array((opener.blockedPopups + [action.request.url ?? URL(string: "about:blank")!]).suffix(20))
            }
            return nil
        }
        // Open Link in New Tab: behind this one, as a ⌘-click's; one that
        // waits to be shown is made without the page WebKit asks for.
        if ask == .behind, Self.backgroundTabsWait, let url = action.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            withAnimation(.slide) { _ = openBehind(url) }
            return nil
        }
        let tab = Tab(configuration: configuration, opener: opener)
        withAnimation(.slide) { add(tab, inBackground: ask == .behind) }
        return tab.webView
    }

    /// The windows the tab's page was kept from opening that can still be
    /// opened, each in a tab of its own that hands back to the page when it
    /// closes. Those its script was to fill can't be: the script has moved on.
    func showBlockedPopups(of tab: Tab) {
        let addresses = tab.blockedPopups.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        tab.blockedPopups = []
        for url in addresses {
            let popup = Tab()
            popup.opener = tab.id
            withAnimation(.slide) { add(popup) }
            popup.go(to: url)
        }
    }

    /// Always Allow on This Site: its windows open from now on, and those just
    /// kept back open now.
    func allowPopups(of tab: Tab) {
        guard let site = tab.site else { return }
        var options = siteSettings.options(for: site)
        options.allowsPopups = true
        changeSiteOptions(options, for: site)
        showBlockedPopups(of: tab)
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
        let answer = await ask(Self.says(frame), prompt, over: webView, buttons: ["OK", "Cancel"], accessory: field, focus: field)
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
    /// show what it is about. `whileThere`: cancelled once the page has
    /// gone on without an answer (`left`), rather than left over the next.
    private func ask(_ title: String, _ message: String, over webView: WKWebView, buttons: [String] = ["OK"],
                     accessory: NSView? = nil, focus: NSView? = nil, whileThere: Bool = false) async -> NSApplication.ModalResponse {
        guard let window = await window(showing: webView) else { return .cancel }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = focus
        // Tab goes through the fields of the accessory, then the buttons.
        alert.window.autorecalculatesKeyViewLoop = true
        let watch = whileThere ? Task {
            await left(webView)
            if !Task.isCancelled { window.endSheet(alert.window, returnCode: .cancel) }
        } : nil
        defer { watch?.cancel() }
        return await alert.beginSheetModal(for: window)
    }

    /// Returns once the page has gone on from where it was: to another
    /// address (typed, a redirect, its script), stopped loading, as when
    /// WebKit gives up the load, or let go of, asleep or with its tab.
    func left(_ webView: WKWebView) async {
        guard let tab = tab(for: webView) else { return }
        let url = tab.url, loading = tab.isLoading
        while tab.page === webView, tabs.contains(where: { $0 === tab }), tab.url == url, tab.isLoading || !loading {
            await withCheckedContinuation { changed in
                withObservationTracking {
                    _ = (tab.url, tab.isLoading, tab.isAsleep, tabs)
                } onChange: {
                    changed.resume()
                }
            }
            if Task.isCancelled { return }
        }
    }

    /// The page's own window, once its tab is the one on screen. A page out of
    /// sight waits for you to go to it, as in Chrome, rather than bring its
    /// tab forward: an alert would otherwise take you away from the tab you
    /// are on, to whatever the page wanted to show. nil if the tab goes, or
    /// sleeps, meanwhile.
    /// Looked at again each time the tab on screen, the lock or the tabs
    /// change, rather than every moment. A tab that sleeps meanwhile is let go
    /// of at the next of those, as sleeping changes none of them.
    func window(showing webView: WKWebView) async -> NSWindow? {
        guard let tab = tab(for: webView) else { return nil }
        while tab.id != selectedID || locked {
            await withCheckedContinuation { changed in
                withObservationTracking {
                    _ = (selectedID, locked, tabs)
                } onChange: {
                    changed.resume()
                }
            }
            guard tab.page === webView, tabs.contains(where: { $0 === tab }) else { return nil }
        }
        return webView.window ?? window
    }
}

extension Browser: WKNavigationDelegate {
    nonisolated static func onlyChangesFragment(from previous: URL?, to next: URL) -> Bool {
        guard let previous, previous != next,
              var old = URLComponents(url: previous, resolvingAgainstBaseURL: false),
              var new = URLComponents(url: next, resolvingAgainstBaseURL: false) else { return false }
        old.fragment = nil
        new.fragment = nil
        return old == new
    }

    /// Each load, a frame's too, runs the page's scripts unless its tab has
    /// them off (Develop › Disable JavaScript).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = tab(for: webView)?.javaScriptOff != true
        if action.targetFrame?.isMainFrame ?? true {
            siteSettings.applyBlocking(to: preferences, for: action.request.url)
            if HTTPSUpgrade.isOn, let url = action.request.url, httpsUpgrade.applies(to: url) {
                preferences.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
            }
        } else if let frame = Self.handle(of: action.targetFrame) {
            if Self.clicked(action) { clickedFrames.insert(frame) } else { clickedFrames.remove(frame) }
        }
        let policy = await policy(for: action, in: webView)
        // A departure asked about but not taken asks again next time.
        if policy != .allow, action.targetFrame?.isMainFrame == true { tab(for: webView)?.departureApproved = false }
        return (policy, preferences)
    }

    private func policy(for action: WKNavigationAction, in webView: WKWebView) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.shouldPerformDownload {
            return mayDownload(from: action.sourceFrame, in: webView, clicked: Self.clicked(action)) ? .download : .cancel
        }
        // Back, Forward and Reload leave an edited page from the browser; an
        // address typed is asked in `Tab.go`. Links and the page's own
        // navigations (a sign-in's redirect) are the page's to ask about,
        // with beforeunload, as in Chrome and Safari.
        if action.targetFrame?.isMainFrame == true, [.backForward, .reload].contains(action.navigationType),
           let tab = tab(for: webView), tab.hasUnsavedWork, !tab.departureApproved,
           !Self.onlyChangesFragment(from: webView.url, to: url) {
            guard await confirmDiscarding(on: webView) else { return .cancel }
            tab.departureApproved = true
        }

        // An extension's sign-in coming back: the address is its answer,
        // handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView)
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame ?? true, browser: self, from: webView) {
            return .cancel
        }
        // An extension's page sending its tab to a website: the tab makes
        // itself a page for the web (see Tab.go).
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), action.targetFrame?.isMainFrame ?? true,
           let tab = tab(for: webView), tab.madeFor != nil {
            Task { tab.go(to: url) }
            return .cancel
        }
        // And a website sending it to one of an extension's pages the
        // extension lets that site open, as Nord Account ends NordPass's
        // sign-in: the tab makes itself a page for the extension. In a
        // page for the web it fails to load. The site is the page's that
        // asked, not the tab's address, which in a redirect is already the
        // extension's page; and only a plain GET from the page itself, not
        // a form or a frame inside it.
        if let host = Extensions.host(of: url), action.targetFrame?.isMainFrame ?? true,
           let tab = tab(for: webView), tab.madeFor != host {
            tab.returning = nil
            let frame = action.sourceFrame
            if frame.isMainFrame, (action.request.httpMethod ?? "GET") == "GET",
               action.request.httpBody == nil, action.request.httpBodyStream == nil {
                let origin = frame.securityOrigin
                if !origin.host.isEmpty {
                    var site = URLComponents()
                    site.scheme = origin.protocol
                    site.host = origin.host
                    if origin.port > 0 { site.port = origin.port }
                    if Extensions.shared.opens(url, from: site.url) {
                        Task { tab.go(to: url) }
                        return .cancel
                    }
                } else if [nil, "about:blank"].contains(frame.request.url?.absoluteString) {
                    // A tab with no page yet has no site to ask for it: the
                    // server that redirects it here is known only after.
                    tab.returning = url
                }
            }
        }
        // 0.0.0.0, the address local servers print as where they listen, is
        // refused by WebKit; it means this Mac, so 127.0.0.1 is opened instead.
        if action.targetFrame?.isMainFrame ?? true, url.host() == "0.0.0.0",
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.host = "127.0.0.1"
            if let local = parts.url { webView.load(.page(local)) }
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
            withAnimation(.slide) { _ = openBehind(url) }
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
            Task { webView.load(.page(url)) }
            return .cancel
        }
        let http = response.response as? HTTPURLResponse
        // A redirect is followed, whatever it says it is: youtube.com sends its
        // move to www.youtube.com as application/binary, which would be saved.
        if let status = http?.statusCode, (300..<400).contains(status) { return .allow }
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let download = !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment")
        if !response.isForMainFrame, let frame = Self.frame(of: response) {
            let clicked = Self.handle(of: frame).map { clickedFrames.remove($0) != nil } ?? true
            if download, !mayDownload(from: frame, in: webView, clicked: clicked) { return .cancel }
        }
        return download ? .download : .allow
    }

    /// The page itself, and a frame of the page's own site, may start a
    /// download; a frame from another site only after a click or a key in
    /// it, as in Chrome: an ad's frame can't push a file on you by itself.
    private func mayDownload(from frame: WKFrameInfo, in webView: WKWebView, clicked: Bool) -> Bool {
        let origin = frame.securityOrigin
        return frame.isMainFrame || Self.mayDownload(from: (origin.protocol, origin.host, origin.port), on: webView.url, clicked: clicked)
    }

    nonisolated static func mayDownload(from origin: (scheme: String, host: String, port: Int), on page: URL?, clicked: Bool) -> Bool {
        guard !clicked else { return true }
        guard let page, let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased() else { return false }
        // WebKit gives an origin on its scheme's own port as port 0.
        func port(_ port: Int?, _ scheme: String) -> Int { port == ["http": 80, "https": 443][scheme] ? 0 : port ?? 0 }
        return origin.scheme.lowercased() == scheme && origin.host.lowercased() == host
            && port(origin.port, scheme) == port(page.port, scheme)
    }

    /// Whether a click or a key in the page started it, by WebKit's own
    /// record of the gesture (SPI). Should that go, a link followed counts,
    /// which a page's script can pass off as one.
    private static func clicked(_ action: WKNavigationAction) -> Bool {
        let key = "_isUserInitiated"
        guard action.responds(to: NSSelectorFromString(key)) else { return action.navigationType == .linkActivated }
        return action.value(forKey: key) as? Bool ?? false
    }

    /// The frame a response is for, and WebKit's handle for a frame, the same
    /// from its navigation's start to its response (SPI). Should either go,
    /// a frame's downloads start as they did before.
    private static func frame(of response: WKNavigationResponse) -> WKFrameInfo? {
        guard response.responds(to: NSSelectorFromString("_frame")) else { return nil }
        return response.value(forKey: "_frame") as? WKFrameInfo
    }

    private static func handle(of frame: WKFrameInfo?) -> NSObject? {
        guard let frame, frame.responds(to: NSSelectorFromString("_handle")) else { return nil }
        return frame.value(forKey: "_handle") as? NSObject
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

    /// Download Linked File in a link's right-click menu. WebKit starts the
    /// download itself and hands it only to a navigation delegate that
    /// answers this name (SPI, as Safari's); unanswered, the file went nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func contextMenuDidCreate(_ webView: WKWebView, download: WKDownload) {
        track(download)
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

    func resume(_ item: Download) {
        guard downloads.contains(where: { $0 === item }), item.canResume || item.canRetry, let old = item.task else { return }
        let data = item.resumeData
        let request = old.originalRequest
        // Reserve the item before awaiting WebKit so a second click cannot
        // start another download. Keep the same row and extension ownership.
        item.restart(with: old, resuming: data != nil)
        Task {
            // A page awake already, or one of this window's store (an
            // incognito download keeps its cookies), never woken for this.
            let page = selected?.page ?? tabs.lazy.compactMap(\.page).first ?? {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = dataStore
                return WKWebView(frame: .zero, configuration: configuration)
            }()
            let task: WKDownload
            if let data { task = await page.resumeDownload(fromResumeData: data) }
            else if let request { task = await page.startDownload(using: request) }
            else { return }
            guard item.state == .running, downloads.contains(where: { $0 === item }) else {
                _ = await task.cancel()
                return
            }
            task.delegate = self
            item.restart(with: task, resuming: data != nil)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        retried = nil
        guard let tab = tab(for: webView) else { return }
        tab.pageDidCommit()
        // Each site's page opens at its site's zoom, or else the one pages
        // open at; one with no site (a file) keeps its tab's.
        if SiteSettings.site(webView.url) != nil {
            webView.pageZoom = siteSettings.zoom(for: webView.url) ?? PageZoom.current
        }
        if HTTPSUpgrade.isOn, let url = webView.url { httpsUpgrade.committed(url) }
        tab.failure = nil
        if !tab.blockedPopups.isEmpty { tab.blockedPopups = [] }
        tab.recordVisit()
        hideChoices(on: tab)
        // A new document has nothing on show.
        if fullscreenTab == tab.id { fullscreenTab = nil }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab(for: webView)?.loading = (navigation, webView.url)
    }

    /// A server sending a tab with no page yet on to an extension's page
    /// that extension lets it open: as a site's own page asking (see
    /// `policy`), judged by the server that sent it.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView), let loading = tab.loading, loading.navigation === navigation else { return }
        let target = tab.returning
        tab.returning = nil
        tab.loading = (navigation, webView.url)
        guard let url = webView.url, url == target, Extensions.shared.opens(url, from: loading.site) else { return }
        webView.stopLoading()
        Task { tab.go(to: url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab(for: webView)?.pageDidLoad()
        tab(for: webView)?.checkReadable()
        if let tab = tab(for: webView) {
            signInLanded(on: tab)
            formLanded(on: tab)
        }
        WebStore.tell(webView)
        sessionChanged()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.departureApproved = false
        show(error, in: webView, opening: navigation)
    }

    /// A page that breaks off after it began to show (the connection lost
    /// halfway) says why too, rather than staying half drawn.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        show(error, in: webView, opening: navigation)
    }

    private func show(_ error: Error, in webView: WKWebView, opening navigation: WKNavigation?) {
        let error = error as NSError
        // Stopped, overtaken by another load, turned into a download (WebKit's
        // 102), or handed to a plug-in (204): nothing went wrong.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code)) { return }
        // Not every error says its address: then it is the one being opened,
        // as the page had it when it set off, or the one on show.
        guard let tab = tab(for: webView) else { return }
        let setOff = tab.loading.flatMap { $0.navigation === navigation ? $0.site : nil }
        guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? setOff ?? webView.url ?? tab.site else { return }
        tab.failure = (url, error.localizedDescription)
    }

    /// A certificate the Mac doesn't trust is refused, as ever, except on this
    /// Mac itself: a local server with a certificate of its own, as developers
    /// run, opens, as Chrome and Search let it. Nothing can be in between there.
    /// A site's own sign-in (Basic, Digest, NTLM, Kerberos) takes the password
    /// already saved for it, or asks for one, and a site asking who you are
    /// by certificate the one chosen for it this session, or else asks which,
    /// even with only one: a certificate tells the site who you are. Without
    /// an answer WebKit goes on as it would: the page is never stopped.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        var credential: URLCredential?
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if let trust = space.serverTrust, Self.isThisMac(space.host) { credential = URLCredential(trust: trust) }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate:
            credential = Self.savedLogin(for: challenge)
            if credential == nil { credential = await askForLogin(challenge, on: webView) }
        case NSURLAuthenticationMethodClientCertificate:
            let host = space.host.lowercased()
            let identities = await Self.identities(issuedBy: space.distinguishedNames ?? [])
            var identity = chosenCertificates[host].flatMap { chosen in identities.first { CFEqual($0, chosen) } }
            if identity == nil, !identities.isEmpty {
                identity = await chooseCertificate(identities, for: space.host, on: webView)
                if let identity { chosenCertificates[host] = identity }
            }
            credential = identity.map { URLCredential(identity: $0, certificates: nil, persistence: .forSession) }
        default:
            break
        }
        return credential.map { (.useCredential, $0) } ?? (.performDefaultHandling, nil)
    }

    /// The password WebKit offers for a sign-in, or the one the Mac keeps for
    /// the place; none once it has been turned down, which would only go
    /// round again.
    nonisolated static func savedLogin(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.previousFailureCount == 0 else { return nil }
        return [challenge.proposedCredential, URLCredentialStorage.shared.defaultCredential(for: challenge.protectionSpace)]
            .lazy.compactMap(\.self).first(where: \.hasPassword)
    }

    /// Certificates with their key in the keychain, issued under one of
    /// `names` (each a DER distinguished name), or every one with none.
    @concurrent nonisolated static func identities(issuedBy names: [Data]) async -> [SecIdentity] {
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
        if !names.isEmpty { query[kSecMatchIssuers] = names }
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return [] }
        return found as? [SecIdentity] ?? []
    }

    /// Safari's sheet for a site's own sign-in, over its page once its tab is
    /// on screen: filled in with the account saved for that very host and
    /// port (`loginKey`), or after a wrong password, with the name just tried.
    /// A password that gets in is offered to keep, as one typed into a page
    /// is (`signInLanded`); a proxy's is neither filled in nor offered.
    /// Cancelled, the page shows the site's own answer to no sign-in; the
    /// sheet goes by itself once the tab has gone on without it.
    private func askForLogin(_ challenge: URLAuthenticationChallenge, on webView: WKWebView) async -> URLCredential? {
        let space = challenge.protectionSpace
        let key = Self.loginKey(for: space)
        let clear = space.protocol == NSURLProtectionSpaceHTTP
        // Asked again: the last try was turned down, and is nothing to keep.
        let tried = tab(for: webView)?.signIn
        tab(for: webView)?.signIn = nil
        guard await window(showing: webView) != nil else { return nil }
        var user = ""
        var password = ""
        if challenge.previousFailureCount > 0 {
            user = challenge.proposedCredential?.user ?? (key != nil && tried?.host == key ? tried?.user : nil) ?? ""
        } else if Passwords.fills, let key,
                  let account = await vault.accounts(for: key, clear: clear).first(where: { $0.host == key }) {
            user = account.user
            password = await vault.password(for: account) ?? ""
        }

        let name = NSTextField(string: user)
        let secret = NSSecureTextField(string: password)
        name.setAccessibilityLabel("User Name")
        secret.setAccessibilityLabel("Password")
        for field in [name, secret] { field.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        let form = NSGridView(views: [[NSTextField(labelWithString: "User Name:"), name],
                                      [NSTextField(labelWithString: "Password:"), secret]])
        form.rowAlignment = .firstBaseline
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 8
        form.frame.size = form.fittingSize

        let (title, note) = Self.loginText(for: space)
        let answer = await ask(title, note, over: webView, buttons: ["Log In", "Cancel"],
                               accessory: form, focus: user.isEmpty ? name : secret, whileThere: true)
        guard answer == .alertFirstButtonReturn else { return nil }
        if let key, !secret.stringValue.isEmpty, let tab = tab(for: webView) {
            tab.signIn = SentSignIn(host: key, user: name.stringValue, password: secret.stringValue, clear: clear, at: .now)
        }
        return URLCredential(user: name.stringValue, password: secret.stringValue, persistence: .forSession)
    }

    /// Where a site's sign-in is saved and filled in from: its host, with
    /// the port when it isn't the scheme's own, as two servers of one site
    /// (a router's pages and its printer's) each have their own. None for a
    /// proxy, whose password is not a site's to keep or offer.
    nonisolated static func loginKey(for space: URLProtectionSpace) -> String? {
        space.isProxy() ? nil : Site.key(place(of: space))
    }

    /// The host, with its port when it isn't the scheme's own.
    private nonisolated static func place(of space: URLProtectionSpace) -> String {
        guard space.port > 0, ["http": 80, "https": 443][space.protocol?.lowercased() ?? ""] != space.port else { return space.host }
        return "\(space.host):\(space.port)"
    }

    /// What the sign-in sheet says: where you log in, and whether the
    /// password goes there in the clear.
    nonisolated static func loginText(for space: URLProtectionSpace) -> (title: String, note: String) {
        let place = space.isProxy() ? "proxy \(place(of: space))" : place(of: space)
        return ("Log in to \(place)", space.receivesCredentialSecurely
                ? "Your login information will be sent securely."
                : "Your login information will not be sent securely.")
    }

    /// The Mac's own sheet for choosing among the certificates the site would
    /// take, each with its name, issuer and expiry, as Safari shows it: over
    /// the page once its tab is on screen. Cancelled, none is sent.
    private func chooseCertificate(_ identities: [SecIdentity], for host: String, on webView: WKWebView) async -> SecIdentity? {
        guard let window = await window(showing: webView), let panel = SFChooseIdentityPanel.shared() else { return nil }
        panel.setInformativeText("Choose the certificate to use with this site, then click Continue.")
        panel.setDefaultButtonTitle("Continue")
        panel.setAlternateButtonTitle("Cancel")
        let end = SheetEnd()
        let chosen = await withCheckedContinuation { done in
            end.done = { done.resume(returning: $0 == NSApplication.ModalResponse.OK.rawValue) }
            panel.beginSheet(for: window, modalDelegate: end, didEnd: #selector(SheetEnd.sheetDidEnd(_:returnCode:contextInfo:)),
                             contextInfo: nil, identities: identities, message: "\(host) asks for a certificate to identify you.")
        }
        return withExtendedLifetime(end) { chosen ? panel.identity()?.takeUnretainedValue() : nil }
    }

    /// localhost and its names, and the loopback addresses (127.x.x.x, ::1).
    /// macOS answers every name under localhost with this Mac itself. Digits
    /// only: a number may otherwise carry a sign ("+1").
    nonisolated static func isThisMac(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
            || (parts.count == 4 && parts.first == "127"
                && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil })
    }

    /// The page's process died (out of memory, or a WebKit bug): it would stay
    /// blank, so it is loaded again, as Safari does. One out of sight sleeps
    /// instead, and loads when it is next shown: reloading it now would only
    /// add to the memory it may have died for. A page that dies again within
    /// a minute would only keep reloading, and says so instead; ⌘R tries again.
    /// So does a page that had something typed into it (`hasUnsavedWork`):
    /// that went with the process, and a page loaded afresh in its place
    /// would hide that it was lost.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if fullscreenTab == tab.id { fullscreenTab = nil }
        let again = tab.crashed.map { Date.now.timeIntervalSince($0) < 60 } ?? false
        tab.crashed = .now
        let edited = tab.hasUnsavedWork
        // Nothing is left to protect: closing or quitting needn't ask.
        tab.hasUnsavedWork = false
        if again || edited, let url = webView.url ?? tab.site {
            tab.failure = (url, again ? "The page crashed each time it was opened."
                                      : "The page crashed. Changes you made in it may not have been saved.")
        } else if tab.id == selectedID {
            webView.reload()
        } else {
            tab.sleep()
        }
    }
}

/// Hears a SecurityInterface sheet end, which it tells by selector, as
/// sheets did before blocks.
final class SheetEnd: NSObject {
    var done: ((Int) -> Void)?

    @objc func sheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        done?(returnCode)
        done = nil
    }
}

/// Downloads go to the folder chosen in Settings (~/Downloads) under the name
/// the site gives, numbered when that is taken, or where each is saved when
/// Nerda is to ask; and bounce the Downloads stack in the Dock when done.
extension Browser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        if let item = item(for: download), item.isResuming, let file = item.file { return file }
        guard let file = await whereToSave(suggestedFilename) else {
            withAnimation(.slide) { downloads.removeAll { $0.task === download } }
            return nil
        }
        item(for: download)?.file = file
        return file
    }

    /// The file a download named so goes to; nil when the question is cancelled.
    private func whereToSave(_ name: String) async -> URL? {
        if downloadFolder == nil, Downloads.asks, let window {
            let panel = NSSavePanel()
            panel.directoryURL = Downloads.folder
            panel.nameFieldStringValue = Downloads.destination(for: name, in: Downloads.folder).lastPathComponent
            guard await panel.beginSheetModal(for: window) == .OK, let file = panel.url else { return nil }
            // Replacing was agreed to in the panel; WebKit won't write over a file.
            try? FileManager.default.removeItem(at: file)
            return file
        }
        return Downloads.destination(for: name, in: downloadFolder ?? Downloads.folder)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole, only to a UI delegate that
    /// answers this name (SPI, as Safari's); unanswered, the button did nothing.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func saveData(_ webView: WKWebView, data: Data?, suggestedFilename: String?, mimeType: String?, originatingURL: URL?) {
        guard let data else { return }
        Task {
            guard let file = await whereToSave(suggestedFilename ?? "") else { return }
            let item = Download(saving: file, size: Int64(data.count))
            withAnimation(.slide) { downloads.insert(item, at: 0) }
            do {
                try data.write(to: file)
                item.finish()
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
            } catch {
                item.fail(error, resumeData: nil)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.finish()
        if let file = item.file {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        item(for: download)?.fail(error, resumeData: resumeData)
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
        guard SearchSuggestions.isOn, let request = SearchEngine.current.guesses(text),
              let (data, _) = try? await URLSession.shared.data(from: request),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [Any],
              reply.count > 1, let suggestions = reply[1] as? [String]
        else { return [] }
        return suggestions
    }
}
