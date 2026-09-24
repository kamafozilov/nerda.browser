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
    /// Set when the last address could not be opened: the page shows why
    /// instead, and Reload tries that address again.
    var failure: (url: URL, message: String)?
    /// Kept at the top of the sidebar as a tile, and never put to sleep: the
    /// sites always open. See `Browser.setPinned`.
    var isPinned = false
    /// Where a pinned tab was when pinned; double-clicking its tile goes back there.
    var home: URL?
    /// The tab whose page opened this one, which closing it goes back to.
    @ObservationIgnored weak var opener: Tab?
    /// Told what the page does (the Browser), by every page the tab makes.
    @ObservationIgnored weak var delegate: (any WKUIDelegate & WKNavigationDelegate)? {
        didSet {
            page?.uiDelegate = delegate
            page?.navigationDelegate = delegate
        }
    }
    /// When the tab was last on screen, so it sleeps only once it has been away a while.
    @ObservationIgnored var lastSeen = Date.now
    /// The page, while awake.
    @ObservationIgnored private(set) var page: WKWebView?
    /// What a sleeping page needs to wake as it was: its history, where it
    /// was scrolled to, and its zoom.
    @ObservationIgnored private var slept: (state: Any?, zoom: CGFloat)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The address last put in history, so a page is counted once per visit,
    /// not again when it wakes or reloads.
    @ObservationIgnored private var recorded: URL?
    /// When the page's process last died, to tell a page that keeps crashing.
    @ObservationIgnored var crashed: Date?

    /// The page, woken first if the tab was asleep.
    var webView: WKWebView { page ?? wake() }
    var isAsleep: Bool { page == nil }

    /// The site the tab is about: the one that failed, if one did.
    var site: URL? { failure?.url ?? url }

    /// The page's own title; until it has one, the site's name, or for an
    /// address without one (file:, about:blank), the address itself.
    var title: String {
        if failure == nil, !pageTitle.isEmpty { return pageTitle }
        guard let site else { return "Untitled" }
        guard let host = site.host(percentEncoded: false), !host.isEmpty else { return site.absoluteString }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // localhost:3000 and localhost:8080 are two different sites.
        return site.port.map { "\(name):\($0)" } ?? name
    }

    /// A page's own tab, or, given the configuration WebKit hands over, one for a
    /// window a page opens, so that it can still talk to its opener (sign-in popups).
    init(configuration: WKWebViewConfiguration = Tab.configuration) {
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
    }

    /// What it takes to open the tab again at the next launch. Only pages from
    /// the web or disk: a blob: or data: address can't be opened again.
    var saved: Session.Tab? {
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
                           zoom: page?.pageZoom ?? slept?.zoom ?? 1, pinned: isPinned ? true : nil, home: home)
    }

    convenience init(url: URL) {
        self.init()
        self.url = url
        webView.load(URLRequest(url: url))
    }

    private func makePage(_ configuration: WKWebViewConfiguration) -> WKWebView {
        let page = SwipingWebView(frame: .zero, configuration: configuration)
        page.isInspectable = true
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
                    if let url = page.url, let title = page.title { History.shared.name(url, title) }
                }
            },
            page.observe(\.isLoading) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.isLoading = page.isLoading }
            },
        ]
        return page
    }

    /// Lets the page go, keeping what it takes to bring it back. Its process
    /// ends with it, and with that the memory, which is most of a tab's cost.
    func sleep() {
        guard let page else { return }
        slept = (page.interactionState, page.pageZoom)
        observations = []
        page.removeFromSuperview()
        self.page = nil
        isLoading = false
    }

    @discardableResult
    private func wake() -> WKWebView {
        let page = makePage(Self.configuration)
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

    /// Puts the page's address in history, once it is really there: loaded,
    /// not just asked for (a mistyped address that fails is not a visit).
    func recordVisit() {
        guard let page, let url = page.url, url != recorded,
              page.backForwardList.currentItem?.url == url else { return }
        recorded = url
        History.shared.visit(url, title: page.title ?? "")
    }

    /// Reload, or after a failure, another go at the address that failed.
    func reload() {
        if let failure {
            webView.load(URLRequest(url: failure.url))
        } else {
            webView.reload()
        }
    }

    /// A pinned tab back where it was pinned.
    func goHome() {
        guard let home else { return }
        webView.load(URLRequest(url: home))
    }

    /// The steps ⌘+ and ⌘− go through, as Safari's do.
    private static let zoomLevels: [CGFloat] = [0.5, 0.67, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// One step in or out (+1, −1), or back to actual size (0).
    // ponytail: per tab; Safari keeps zoom per site across launches, once settings are saved.
    func zoom(_ step: Int) {
        let now = webView.pageZoom
        let next: CGFloat? = switch step {
        case 0: 1
        case 1...: Self.zoomLevels.first { $0 > now + 0.01 }
        default: Self.zoomLevels.last { $0 < now - 0.01 }
        }
        if let next { webView.pageZoom = next }
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
    }

    /// Once the page is in, and only if /favicon.ico gave nothing: the icon
    /// the page itself names, fetched from inside the page, so it comes with
    /// the page's cookies past checks (Cloudflare's) that turn a bare request away.
    func pageDidLoad() {
        guard let page, let site = Favicons.origin(of: url), Favicons.shared.images[site] == nil else { return }
        Task {
            let icon = try? await page.callAsyncJavaScript(Self.findIcon, contentWorld: .defaultClient) as? String
            await Favicons.shared.load(site, icon: icon.flatMap(URL.init(string:)))
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

    private static var configuration: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = applicationName
        // WebKit's full screen, under our own (see Fullscreen). Pages a page
        // opens (popups) are given this configuration's, script and all.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(Fullscreen.script)
        configuration.userContentController.add(Fullscreen.messages, contentWorld: .page, name: "fullscreen")
        return configuration
    }

    /// Sites serve their full pages only to browsers that say they are Safari;
    /// without this Google, for one, sends its bare fallback. Safari's own
    /// version, so it keeps up with the system.
    private static let applicationName: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "26.0") Safari/605.1.15"
    }()
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
    /// How much of the page's left side the sidebar covers. The page lays
    /// itself out in the rest, without the web view changing size.
    var coveredLeading: CGFloat = 0

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // First, so that a sleeping tab's page is woken and among the rest.
        let shown = selected?.webView
        let pages = tabs.compactMap(\.page)
        // Closed tabs' pages go (sleeping ones take themselves out).
        for page in view.subviews where !pages.contains(where: { $0 === page }) {
            page.removeFromSuperview()
        }
        for page in pages {
            let arriving = page.superview !== view || page.isHidden
            if page.superview !== view {
                page.frame = view.bounds
                page.autoresizingMask = [.width, .height]
                view.addSubview(page)
            }
            cover(page)
            page.isHidden = page !== shown
            if page === shown, arriving, takesFocus {
                DispatchQueue.main.async { page.window?.makeFirstResponder(page) }
            }
        }
    }

    private func cover(_ webView: WKWebView) {
        guard #available(macOS 26, *), webView.obscuredContentInsets.left != coveredLeading else { return }
        webView.obscuredContentInsets = NSEdgeInsets(top: 0, left: coveredLeading, bottom: 0, right: 0)
    }

    /// Whether pages can be told what covers them (macOS 26), rather than be
    /// made narrower, which WebKit catches up with a frame or more late.
    static var canBeCovered: Bool {
        if #available(macOS 26, *) { true } else { false }
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
