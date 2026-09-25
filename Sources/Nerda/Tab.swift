import SwiftUI
import WebKit

/// One page, and what the sidebar shows for it. The page lives while the tab
/// is in use, so switching away and back finds it as it was left; a tab left
/// alone long enough sleeps, giving the page's memory back, and wakes where it
/// was (history, scroll position) when it is next shown.
@Observable
final class Tab: Identifiable {
    let id = UUID()
    /// Where the page is now, which is not where it started once links are followed.
    private(set) var url: URL?
    private var pageTitle = ""
    private(set) var isLoading = false
    /// For the address bar's buttons, and the line under it that fills as the page loads.
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var progress = 0.0
    /// The colour the page gives its top (its theme colour), or else its
    /// background: the address bar wears it, so it reads as part of the page.
    private(set) var color: NSColor?
    /// Set when the last address could not be opened: the page shows why
    /// instead, and Reload tries that address again.
    var failure: (url: URL, message: String)?
    /// Kept at the top of the sidebar as a tile, and never put to sleep for
    /// being idle: the sites always open. ⌘W lets its page go, tile and all
    /// kept (`Browser.closeSelectedTab`). See `Browser.setPinned`.
    var isPinned = false
    /// Where a pinned tab was when pinned; double-clicking its tile goes back there.
    var home: URL?
    /// The bookmark it is the tab of (`Browser.open(bookmark:)`): shown in
    /// the bookmark's place in the sidebar, not in the list.
    var bookmark: Bookmarks.Item.ID?
    /// A name of your own for the tab (double-click it in the sidebar), kept
    /// in place of the page's title wherever the tab goes.
    var name: String?
    /// Nerda's settings, open on this page of them, in place of a web page.
    var settings: SettingsPage?
    /// Every page visited (⌘Y), in place of a web page.
    var showsHistory = false
    /// Told what the page does (the Browser), by every page the tab makes.
    @ObservationIgnored weak var delegate: (any WKUIDelegate & WKNavigationDelegate)? {
        didSet {
            page?.uiDelegate = delegate
            page?.navigationDelegate = delegate
        }
    }
    /// Where the page keeps its cookies, cache and site data: on disk, or for
    /// an incognito window's tabs, in memory until that window closes.
    @ObservationIgnored var dataStore = WKWebsiteDataStore.default()
    /// When the tab was last on screen, so it sleeps only once it has been away a while.
    @ObservationIgnored var lastSeen = Date.now
    /// The page, while awake.
    @ObservationIgnored private(set) var page: WKWebView?
    /// What a sleeping page needs to wake as it was: its history, where it
    /// was scrolled to, and its zoom.
    @ObservationIgnored private var slept: (state: Any?, zoom: CGFloat)?
    /// The top of the page as it went to sleep, for its hover card (`TabPeek`).
    @ObservationIgnored private(set) var look: NSImage?
    @ObservationIgnored private var observations: [NSObject] = []
    /// The page's top edge, as last sampled (`recolor`): by WebKit, or here.
    @ObservationIgnored private var topColor: NSColor?
    /// The address last put in history, so a page is counted once per visit,
    /// not again when it wakes or reloads.
    @ObservationIgnored private var recorded: URL?
    /// When the page's process last died, to tell a page that keeps crashing.
    @ObservationIgnored var crashed: Date?
    /// A password the page just sent, until it is known whether it got in.
    @ObservationIgnored var signIn: SentSignIn?
    /// A name sent on its own, for the password step that comes after it.
    @ObservationIgnored var nameSent: (host: String, user: String, at: Date)?

    /// The page, woken first if the tab was asleep.
    var webView: WKWebView { page ?? wake() }
    var isAsleep: Bool { page == nil }
    /// A new tab: nowhere yet, and no page until it is told where to go.
    var isBlank: Bool { url == nil && page == nil && settings == nil && !showsHistory }
    /// A web page to show, rather than a new tab's field or the settings.
    var hasPage: Bool { !isBlank && settings == nil && !showsHistory }

    /// An incognito window's: nothing it does is kept (history, icons on disk).
    var isPrivate: Bool { !dataStore.isPersistent }

    /// The site the tab is about: the one that failed, if one did.
    var site: URL? { failure?.url ?? url }

    /// The page's own title; until it has one, the site's name, or for an
    /// address without one (file:, about:blank), the address itself.
    var title: String {
        if let settings { return "Settings › \(settings.title)" }
        if showsHistory { return "History" }
        if let name { return name }
        if failure == nil, !pageTitle.isEmpty { return pageTitle }
        guard let site else { return "New Tab" }
        guard let host = site.host(percentEncoded: false), !host.isEmpty else { return site.absoluteString }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // localhost:3000 and localhost:8080 are two different sites.
        return site.port.map { "\(name):\($0)" } ?? name
    }

    /// A new tab, asking where to go; its page is made once it goes somewhere.
    init() {}

    /// A tab for a window a page opens, on the configuration WebKit hands over,
    /// so that it can still talk to its opener (sign-in popups).
    init(configuration: WKWebViewConfiguration) {
        page = makePage(configuration)
    }

    /// A tab from an earlier run, asleep: it shows its title and icon, and
    /// only loads, back where it was, once it is shown.
    init(restoring saved: Session.Tab) {
        url = saved.url
        recorded = saved.url
        pageTitle = saved.title
        slept = (saved.state, saved.zoom)
        isPinned = saved.pinned == true
        // Sessions from before homes: where it was left is the best guess.
        home = saved.home ?? (isPinned ? saved.url : nil)
        settings = saved.settings
        showsHistory = saved.history == true
        name = saved.name
        bookmark = saved.bookmark
    }

    /// What it takes to open the tab again at the next launch: the settings, or
    /// a page from the web or disk (a blob: or data: address can't be opened again).
    var saved: Session.Tab? {
        if let settings {
            return Session.Tab(url: nil, title: "", state: nil, zoom: 1, pinned: nil, home: nil, settings: settings)
        }
        if showsHistory {
            return Session.Tab(url: nil, title: "", state: nil, zoom: 1, pinned: nil, home: nil, history: true)
        }
        guard let site, ["http", "https", "file"].contains(site.scheme) else { return nil }
        let state: Any?
        if let page {
            // A page that never got there (still loading, or failed) would
            // wake to the one before it, or blank: it is loaded afresh instead.
            state = page.backForwardList.currentItem?.url == site ? page.interactionState : nil
        } else {
            state = slept?.state
        }
        return Session.Tab(url: site, title: failure == nil ? pageTitle : "", state: state as? Data,
                           zoom: page?.pageZoom ?? slept?.zoom ?? 1, pinned: isPinned ? true : nil, home: home,
                           name: name, bookmark: bookmark)
    }

    convenience init(url: URL) {
        self.init()
        go(to: url)
    }

    /// Takes the tab to `url`, a new one included.
    func go(to url: URL) {
        settings = nil
        showsHistory = false
        // Woken first, while it has nowhere to go, or it would load `url` twice.
        let page = webView
        self.url = url
        page.load(URLRequest(url: url))
    }

    private func makePage(_ configuration: WKWebViewConfiguration) -> WKWebView {
        Self.matchScreenRate(configuration.preferences)
        let page = SwipingWebView(frame: .zero, configuration: configuration)
        _ = Self.powerWatch
        Self.pages.add(page)
        page.isInspectable = true
        // A sleeping page wakes at its own zoom (`wake`), set after this.
        page.pageZoom = PageZoom.current
        // See-through until its first page arrives (`pageDidCommit`): a new or
        // woken page is otherwise white while the site answers, a flash in dark
        // mode. The card's own ground shows instead, as another browser keeps
        // what was there. A page that goes on to another keeps its last one
        // meanwhile, WebKit's own doing.
        // WebKit SPI: should it go, the page is white meanwhile, as it was.
        Self.set(page, "_setDrawsBackground:", false)
        // Scrolled to its end, the page stays put, as in Chrome: WebKit's
        // rubber band pulls it on, over a blank ground. No edge bounces.
        // WebKit SPI (`_WKRectEdge`): should it go, pages bounce again.
        Self.set(page, "_setRubberBandingEnabled:", UInt(0))
        page.uiDelegate = delegate
        page.navigationDelegate = delegate
        // WebKit reports these on the main thread, where the tab lives.
        observations = [
            page.observe(\.url) { [weak self] page, _ in
                // nil while a first load fails; the address typed is still the tab's.
                MainActor.assumeIsolated { if let url = page.url { self?.url = url } }
                // A page that changes its address itself (YouTube going to a
                // video) never loads anew: that is a visit too. Asked once the
                // page has caught up, as WebKit tells of the address first.
                DispatchQueue.main.async { self?.recordVisit() }
            },
            page.observe(\.title) { [weak self] page, _ in
                MainActor.assumeIsolated {
                    self?.pageTitle = page.title ?? ""
                    if self?.isPrivate == false, let url = page.url, let title = page.title { History.shared.name(url, title) }
                }
            },
            page.observe(\.isLoading) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.isLoading = page.isLoading }
            },
            // At once too: a page woken from sleep may have no history, where the one before had.
            page.observe(\.canGoBack, options: .initial) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.canGoBack = page.canGoBack }
            },
            page.observe(\.canGoForward, options: .initial) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.canGoForward = page.canGoForward }
            },
            page.observe(\.estimatedProgress) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.progress = page.estimatedProgress }
            },
            page.observe(\.themeColor) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageRecolored() }
            },
            page.observe(\.underPageBackgroundColor) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageRecolored() }
            },
            KeyObserver(page, Self.sampledTopColor) { [weak self] in self?.sampled() },
        ]
        // This page took the process kept ready; the next one is readied once it is under way.
        DispatchQueue.main.async { Self.warmUp() }
        return page
    }

    /// Connects to `url`'s server (its address looked up, the connection and
    /// its encryption set up) ahead of a page asking for it, as Safari's
    /// address bar does: ~250–500 ms off a first visit's wait.
    // WebKit SPI: should it go, pages connect when they load, as they did.
    static func preconnect(to url: URL) {
        let preconnect = NSSelectorFromString("_preconnectToServer:")
        guard ["http", "https"].contains(url.scheme), let pool = processPool as? NSObject,
              pool.responds(to: preconnect) else { return }
        pool.perform(preconnect, with: url)
    }

    /// A link to another site the pointer rests on is connected to on the way
    /// to a click on it, as Chrome does: each site once a page, 20 at most.
    /// In a world of its own, so the page can't ask for connections itself.
    private static let linkHover = WKUserScript(source: """
        (() => {
            const asked = new Set([location.origin]);
            let resting;
            addEventListener('mouseover', event => {
                clearTimeout(resting);
                if (!event.isTrusted) return;
                const link = event.target.closest?.('a[href]');
                if (!link || asked.size > 20) return;
                let url;
                try { url = new URL(link.href); } catch { return; }
                if (!/^https?:$/.test(url.protocol) || asked.has(url.origin)) return;
                resting = setTimeout(() => {
                    asked.add(url.origin);
                    webkit.messageHandlers.preconnect.postMessage(url.origin);
                }, 100);
            }, { capture: true, passive: true });
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    private static let preconnects = Preconnects()

    final class Preconnects: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let origin = message.body as? String, let url = URL(string: origin) else { return }
            Tab.preconnect(to: url)
        }
    }

    /// A middle click on a link opens it in a tab of its own, behind this one,
    /// as ⌘-click does. WebKit leaves the middle button to the page and asks
    /// the browser nothing, so the click is heard here: a real one (not one a
    /// page made up), on a link, that the page left alone.
    private static let middleClick = WKUserScript(source: """
        addEventListener('auxclick', event => {
            if (event.button !== 1 || !event.isTrusted || event.defaultPrevented) return;
            const link = event.composedPath().find(element => element instanceof HTMLAnchorElement || element instanceof HTMLAreaElement);
            if (link?.href) webkit.messageHandlers.middleClick.postMessage(link.href);
        });
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    /// An element moved elsewhere in the page keeps the keyboard, as in
    /// Chrome. WebKit lets it go to the page itself: YouTube's player, moved
    /// into theater mode, lost it, and the arrow keys scrolled the page
    /// instead of setting the volume. So what had it, taken out and put back
    /// with nothing else given the keyboard meanwhile, is given it again.
    private static let keepFocus = WKUserScript(source: """
        (() => {
            let focused = null;
            addEventListener('focusin', event => { focused = event.composedPath()[0]; }, true);
            // Let go of, not taken out: a click elsewhere, or the keyboard moved on.
            addEventListener('focusout', event => { if (event.composedPath()[0].isConnected) focused = null; }, true);
            new MutationObserver(() => {
                if (focused?.isConnected && document.activeElement === document.body) focused.focus({ preventScroll: true });
            }).observe(document, { childList: true, subtree: true });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    private static let middleClicks = MiddleClicks()

    final class MiddleClicks: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let page = message.webView, let browser = page.uiDelegate as? Browser,
                  let address = message.body as? String, let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            withAnimation(.slide) { browser.open(url, inBackground: true) }
        }
    }

    /// Starts a page's process ahead of the page that will need it, as Safari
    /// and Chrome keep one: a tab opened or woken then starts in ~20 ms, not
    /// ~60 ms. WebKit keeps at most one, and lets it go under memory pressure.
    // WebKit SPI: should it go, pages start their own processes, as they did.
    static func warmUp() {
        let warm = NSSelectorFromString("_warmInitialProcess")
        if let pool = processPool as? NSObject, pool.responds(to: warm) { pool.perform(warm) }
    }

    /// The colour along the page's top edge: what the address bar touches,
    /// which sites' theme colours often aren't (GitHub's, YouTube's). None
    /// when the edge isn't one colour; then the page's theme colour, or its background.
    private func recolor() {
        guard let page else { return }
        color = topColor ?? page.themeColor ?? page.underPageBackgroundColor
    }

    /// WebKit samples the top edge once a page is in, as it does for Safari.
    // WebKit SPI, as Safari's own: should it go, the theme colour is the fallback.
    private func sampled() {
        guard let page else { return }
        topColor = page.value(forKey: Self.sampledTopColor) as? NSColor
        recolor()
    }

    private static let sampledTopColor = "_sampledPageTopColor"

    /// The page's own colours changed after WebKit's sample: light or dark
    /// mode switched, or the site's own theme. WebKit won't sample again until
    /// the next page, and the bar would keep the old colour (dark over a
    /// light page), so the edge is sampled here from a snapshot of it, which
    /// a hidden page gives too. While a page loads, WebKit's sample is on its way.
    // ponytail: a snapshot's vivid colours come out a shade off the page's (greys,
    // most sites' tops, match); the next load's WebKit sample puts it right.
    private func pageRecolored() {
        guard let page, topColor != nil, !page.isLoading else { return recolor() }
        let edge = WKSnapshotConfiguration()
        edge.rect = CGRect(x: 0, y: 0, width: page.bounds.width, height: 1)
        Task {
            let strip = try? await page.takeSnapshot(configuration: edge)
            guard self.page === page else { return }
            topColor = strip.flatMap(Self.color(across:))
            recolor()
        }
    }

    /// The colour across a strip of the page, if it is one: five points along
    /// it within 5 of 255 of each other, about what WebKit allows (`configuration`).
    static func color(across strip: NSImage) -> NSColor? {
        guard let image = strip.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let row = NSBitmapImageRep(cgImage: image)
        let points = (0..<5).compactMap { row.colorAt(x: (row.pixelsWide - 1) * $0 / 4, y: 0)?.usingColorSpace(.sRGB) }
        guard points.count == 5, let first = points.first else { return nil }
        let even = points.allSatisfy { point in
            max(abs(point.redComponent - first.redComponent), abs(point.greenComponent - first.greenComponent),
                abs(point.blueComponent - first.blueComponent)) <= 5 / 255
        }
        return even ? first : nil
    }

    /// Lets the page go, keeping what it takes to bring it back. Its process
    /// ends with it, and with that the memory, which is most of a tab's cost.
    /// `look`, the page's top (`snapshot`), stays for its hover card: a few
    /// hundred KB, of the hundreds of MB let go.
    func sleep(keeping look: NSImage? = nil) {
        guard let page else { return }
        self.look = look
        slept = (page.interactionState, page.pageZoom)
        observations = []
        topColor = nil
        page.removeFromSuperview()
        self.page = nil
        isLoading = false
        Self.endServiceWorkers()
    }

    /// The top of the page, as wide as a hover card shows it: a hidden page
    /// gives one too.
    func snapshot() async -> NSImage? {
        guard let page, page.bounds.width > 0 else { return nil }
        let top = WKSnapshotConfiguration()
        top.rect = CGRect(x: 0, y: 0, width: page.bounds.width,
                          height: min(page.bounds.height, page.bounds.width / TabPeek.aspect))
        top.snapshotWidth = NSNumber(value: Double(TabPeek.width))
        return try? await page.takeSnapshot(configuration: top)
    }

    /// What the page's process takes, as Activity Monitor's Memory column
    /// counts it; nil while asleep, or before the page has a process.
    // WebKit SPI, as Bench uses: should it go, the card shows no memory.
    var memory: UInt64? {
        guard let page, page.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (page.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return read == 0 ? usage.ri_phys_footprint : nil
    }

    @discardableResult
    private func wake() -> WKWebView {
        look = nil
        let page = makePage(Self.configuration(dataStore))
        self.page = page
        if let slept { page.pageZoom = slept.zoom }
        if let state = slept?.state {
            page.interactionState = state
        } else if let url {
            page.load(URLRequest(url: url))
        }
        slept = nil
        return page
    }

    /// A page is in: from here on it draws its own background, white for a
    /// site that gives none, as it means to be. WebKit holds the new page back
    /// until it has something to show, so the ground under it never shows through.
    func pageDidCommit() {
        if let page { Self.set(page, "_setDrawsBackground:", true) }
    }

    /// Puts the page's address in history, once it is really there: loaded,
    /// not just asked for (a mistyped address that fails is not a visit).
    func recordVisit() {
        guard !isPrivate, let page, let url = page.url, url != recorded,
              page.backForwardList.currentItem?.url == url else { return }
        recorded = url
        History.shared.visit(url, title: page.title ?? "")
    }

    /// Reload, or after a failure, another go at the address that failed.
    /// From origin, the page and what it loads are fetched anew, not taken
    /// from the cache.
    func reload(fromOrigin: Bool = false) {
        if let failure {
            webView.load(URLRequest(url: failure.url, cachePolicy: fromOrigin ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy))
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    /// A pinned tab back where it was pinned.
    func goHome() {
        guard let home else { return }
        webView.load(URLRequest(url: home))
    }

    /// One step in or out (+1, −1), or back to the zoom pages open at (0).
    // ponytail: per tab; Safari keeps zoom per site across launches.
    func zoom(_ step: Int) {
        let now = webView.pageZoom
        let next: CGFloat? = switch step {
        case 0: PageZoom.current
        case 1...: PageZoom.levels.first { $0 > now + 0.01 }
        default: PageZoom.levels.last { $0 < now - 0.01 }
        }
        if let next { webView.pageZoom = next }
    }

    /// The zoom pages open at changed: a page left at the old one takes the
    /// new one, asleep or awake; one zoomed on its own (⌘+, ⌘−) keeps its zoom.
    func defaultZoomChanged(from old: CGFloat, to new: CGFloat) {
        if let page, abs(page.pageZoom - old) < 0.01 { page.pageZoom = new }
        if let zoom = slept?.zoom, abs(zoom - old) < 0.01 { slept?.zoom = new }
    }

    /// Something the user would notice stopping: sound or video playing, or
    /// the camera or microphone on. A page like that is never put to sleep.
    func isBusy() async -> Bool {
        guard let page else { return false }
        if page.cameraCaptureState != .none || page.microphoneCaptureState != .none { return true }
        return await page.requestMediaPlaybackState() == .playing
    }

    /// For a closed tab: no more sound or video, and the camera and microphone off,
    /// for good. Suspended rather than paused, so the page can't start them again.
    func silence() {
        guard let page else { return }
        page.setAllMediaPlaybackSuspended(true)
        page.setCameraCaptureState(.none)
        page.setMicrophoneCaptureState(.none)
        Self.endServiceWorkers()
    }

    @ObservationIgnored private static var endingWorkers: Task<Void, Never>?

    /// A site's service worker keeps a process of its own (hundreds of MB for
    /// a news site's) long after its pages sleep or close. Half a minute on,
    /// as Chrome ends idle ones, they end; those of pages still open start
    /// again when needed, as service workers are made to.
    // WebKit SPI: should it go, workers end when WebKit sees fit, as they did.
    static func endServiceWorkers() {
        endingWorkers?.cancel()
        endingWorkers = Task {
            try? await Task.sleep(for: .seconds(30))
            let end = NSSelectorFromString("_terminateServiceWorkers")
            guard !Task.isCancelled, let pool = processPool as? NSObject, pool.responds(to: end) else { return }
            pool.perform(end)
        }
    }

    /// Once the page is in, and only if /favicon.ico gave nothing: the icon
    /// the page itself names, fetched from inside the page, so it comes with
    /// the page's cookies past checks (Cloudflare's) that turn a bare request away.
    func pageDidLoad() {
        guard let page, let site = Favicons.origin(of: url), Favicons.shared.images[site] == nil else { return }
        Task {
            let icon = try? await page.callAsyncJavaScript(Self.findIcon, contentWorld: .defaultClient) as? String
            await Favicons.shared.load(site, icon: icon.flatMap(URL.init(string:)), keep: !isPrivate)
        }
    }

    /// The icon's bytes as a data: URL, or where they are when the page may
    /// not read them itself (another origin's).
    private static let findIcon = """
        const link = document.querySelector('link[rel~="icon"]');
        const href = link ? link.href : new URL('/favicon.ico', location.href).href;
        try {
            const response = await fetch(href);
            if (!response.ok) return href;
            let bytes = '';
            for (const byte of new Uint8Array(await response.arrayBuffer())) bytes += String.fromCharCode(byte);
            return 'data:;base64,' + btoa(bytes);
        } catch { return href; }
        """

    private static let processPool = WKWebViewConfiguration().value(forKey: "processPool")

    private static func configuration(_ dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // One pool for every tab. Left to itself each configuration makes its
        // own, and each pool reads every font on the Mac before its first page
        // can start, holding up the window ~30 ms for each tab opened or woken.
        // By key: Apple deprecated the property as having no effect, which it
        // still has (measured on macOS 27).
        configuration.setValue(processPool, forKey: "processPool")
        configuration.applicationNameForUserAgent = applicationName
        // A window a page opens only from a click or a key, as in Safari: on
        // the Mac, WebKit otherwise lets a page open them whenever it likes,
        // on load or on a timer, and each one takes you away to it.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // WebKit's full screen, under our own (see Fullscreen). Pages a page
        // opens (popups) are given this configuration's, script and all.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(Fullscreen.script)
        configuration.userContentController.addUserScript(Fullscreen.bridge)
        configuration.userContentController.add(Fullscreen.messages, contentWorld: .defaultClient, name: "fullscreen")
        Passwords.install(in: configuration.userContentController)
        // The first page made starts the blocker: WebKit is being started for
        // it anyway. Cached rules arrive asynchronously; navigation never waits.
        Blocker.shared.start()
        Blocker.shared.install(in: configuration.userContentController)
        configuration.userContentController.addUserScript(googleSignIn)
        configuration.userContentController.addUserScript(geminiButton)
        configuration.userContentController.addUserScript(linkHover)
        configuration.userContentController.add(preconnects, contentWorld: .defaultClient, name: "preconnect")
        configuration.userContentController.addUserScript(middleClick)
        configuration.userContentController.add(middleClicks, contentWorld: .defaultClient, name: "middleClick")
        configuration.userContentController.addUserScript(keepFocus)
        // WebKit samples the page's top edge only when asked, allowing this
        // much difference across it (as Safari does), for `recolor`.
        set(configuration, "_setSampledPageTopColorMaxDifference:", 5.0)
        // As Safari has them, where WebKit leaves them off for other apps:
        // the sites a page links to are looked up ahead of a click, and a page
        // out of sight has its timers slowed further the longer it stays so.
        set(configuration.preferences, "_setDNSPrefetchingEnabled:", true)
        set(configuration.preferences, "_setHiddenPageDOMTimerThrottlingAutoIncreases:", true)
        // Picture in picture, for Auto Picture-in-Picture and a player's own
        // button: without it WebKit says no video supports it.
        set(configuration.preferences, "_setAllowsPictureInPictureMediaPlayback:", true)
        // A page out of sight that keeps over half a core busy for WebKit's
        // 8 minutes (an ad gone wrong) has its process ended; the tab sleeps
        // (Browser.webViewWebContentProcessDidTerminate) and loads again when
        // next shown. Never one on screen, or playing sound.
        set(configuration, "_setCPULimit:", 0.5)
        return configuration
    }

    /// Calls a setter of WebKit's own (SPI, as Safari uses), if WebKit still has it.
    private static func set(_ object: NSObject, _ setter: String, _ value: Double) {
        let selector = NSSelectorFromString(setter)
        guard object.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
    }

    private static func set(_ object: NSObject, _ setter: String, _ value: UInt) {
        let selector = NSSelectorFromString(setter)
        guard object.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
    }

    private static func set(_ object: NSObject, _ setter: String, _ value: Bool) {
        let selector = NSSelectorFromString(setter)
        guard object.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
    }

    /// Pages drawn at the screen's own rate, up to 120 a second on a ProMotion
    /// screen, as in Chrome; WebKit holds them near 60, as Safari does. In Low
    /// Power Mode they keep WebKit's 60: a page that animates draws half as
    /// often. WebKit reads it as the page is made, before its view is: a tab
    /// follows a change of mode once its page is made again (woken, or opened).
    private static func matchScreenRate(_ preferences: WKPreferences) {
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        guard let near60, preferences.responds(to: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: setter), to: Setter.self)(
            preferences, setter, ProcessInfo.processInfo.isLowPowerModeEnabled, near60)
    }

    /// Every page made, while it lives.
    private static let pages = NSHashTable<WKWebView>.weakObjects()

    /// Low Power Mode turned on or off reaches the pages already open too,
    /// not only those made from then on: WebKit takes it up as each is next
    /// loaded (reloaded, or gone somewhere), rather than when it is woken.
    private static let powerWatch = NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            for page in pages.allObjects { matchScreenRate(page.configuration.preferences) }
        }
    }

    /// WebKit's switch for it, one of the flags Safari lists under Develop ›
    /// Feature Flags; nil in a WebKit without it, which then keeps its own rate.
    static let near60: NSObject? = {
        let features = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: features),
              let all = type.perform(features)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return all.first { $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled" }
    }()

    /// Google's "Sign in with Google" prompt is a light page in an iframe. On a
    /// dark site, WebKit gives an iframe whose colours don't match the site's
    /// a solid background of its own, white here, round the prompt's corners.
    /// Matched to the prompt's, the iframe is see-through, as Google means it to be.
    private static let googleSignIn = WKUserScript(source: """
        const style = document.createElement('style');
        style.textContent = 'iframe[src^="https://accounts.google.com/gsi/"] { color-scheme: normal !important; }';
        document.documentElement.append(style);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    /// Google's "Ask Gemini" button (Gmail's, among others) is a square picture
    /// cut to a star by the clip-path of the box round it. Hovered, the rings
    /// behind it spin, WebKit lifts the picture onto a layer of its own, and a
    /// clip-path on a box not itself on one no longer cuts it: the whole square
    /// shows, black round the star (Safari too). On a layer of its own, the box
    /// cuts all that is in it. Google's class names, which may change.
    private static let geminiButton = WKUserScript(source: """
        {
            const style = document.createElement('style');
            style.textContent = '.HFMVod { will-change: transform; }';
            document.documentElement.append(style);
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    /// Sites serve their full pages only to browsers that say they are Safari;
    /// without this Google, for one, sends its bare fallback. Safari's own
    /// version, so it keeps up with the system.
    private static let applicationName: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "26.0") Safari/605.1.15"
    }()
}

/// KVO on a key WebKit names only privately, which Swift has no key path for.
/// Told on the main thread, as WebKit tells of its other keys; stops when let go.
nonisolated private final class KeyObserver: NSObject {
    private let object: NSObject
    private let key: String
    private let changed: @MainActor @Sendable () -> Void

    init(_ object: NSObject, _ key: String, changed: @escaping @MainActor @Sendable () -> Void) {
        self.object = object
        self.key = key
        self.changed = changed
        super.init()
        object.addObserver(self, forKeyPath: key, context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let changed = changed
        MainActor.assumeIsolated { changed() }
    }

    deinit { object.removeObserver(self, forKeyPath: key) }
}

/// Every awake tab's page, all in the window at once, with only the selected
/// one shown. Switching tabs just shows another, as it was left: a page taken
/// out of the window and put back is set up and drawn again, and blinks blank
/// meanwhile. Hidden, a page keeps its last frame, and WebKit still slows it
/// down as out of sight, as it does a page out of the window.
struct PageView: NSViewRepresentable {
    let tabs: [Tab]
    let selected: Tab?
    /// Whether the page takes the keyboard when it comes on screen, so Space
    /// scrolls it. Not while the command bar has it.
    let takesFocus: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // First, so that a sleeping tab's page is woken and among the rest. A
        // new tab has none to show, and none is made for it.
        let shown = selected.flatMap { $0.hasPage ? $0.webView : nil }
        let awake = tabs.compactMap(\.page)
        // Closed tabs' pages go (sleeping ones take themselves out). Only
        // pages: in its own full screen (a bare `<video controls>`), WebKit
        // leaves a stand-in of its own here.
        for page in view.subviews where page is WKWebView && !awake.contains(where: { $0 === page }) {
            page.removeFromSuperview()
        }
        // A page in WebKit's full screen, or on its way in or out, is WebKit's
        // to place: put back here, its video would go black, its sound playing on.
        let pages = awake.filter { $0.fullscreenState == .notInFullscreen }
        // The page with the keyboard, if one has it. It is handed on before
        // that page hides: a page hidden with the keyboard has AppKit look
        // through every view in the window for the next to take it.
        let window = view.window
        let focused = (window?.firstResponder as? NSView).flatMap { responder in
            pages.first { responder === $0 || responder.isDescendant(of: $0) }
        }
        for page in pages {
            let arriving = page.superview !== view || page.isHidden
            if page.superview !== view {
                page.frame = view.bounds
                page.autoresizingMask = [.width, .height]
                view.addSubview(page)
            }
            guard page === shown else { continue }
            page.isHidden = false
            guard arriving, takesFocus else { continue }
            if let window, focused != nil {
                window.makeFirstResponder(page)
            } else {
                DispatchQueue.main.async { page.window?.makeFirstResponder(page) }
            }
        }
        // With no page on screen (a new tab, the settings), the keyboard
        // leaves the one hidden behind: Space would pause its video unseen.
        if shown == nil, focused != nil { window?.makeFirstResponder(nil) }
        for page in pages where page !== shown { page.isHidden = true }
    }
}

/// In place of a page that could not be opened: what went wrong. ⌘R tries again.
struct PageFailure: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text("Can't Open This Page")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(message)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Text("Press ⌘R to try again.")
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}
