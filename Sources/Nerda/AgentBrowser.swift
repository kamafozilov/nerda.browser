import AppKit
import Observation
import WebKit

/// Where Agent tabs live (GLOSSARY.md): a browser of the profile's own
/// browsing, its cookies and sign-ins, out of the owner's sight. It keeps no
/// session file and adds nothing to history (`Browser.isForAgents`), and its
/// pages are in a window of their own, off screen (`AgentWindow`), never in
/// one of the owner's.
@Observable
final class AgentBrowser {
    let browser: Browser
    let window = AgentWindow()
    /// Agent tabs the owner watches in a window of theirs
    /// (`Browser.watched`): their pages are there, not here.
    var watched: Set<Tab.ID> = []

    init(profile: Profile = .main, dataStore: WKWebsiteDataStore? = nil) {
        browser = Browser(profile: profile, dataStore: dataStore, forAgents: true)
        holdPages()
    }

    var tabs: [Tab] { browser.tabs }

    /// An Agent tab for `url`, behind the others: nothing here is ever on
    /// screen to be put in front of. Its agent is at work in it, so it
    /// loads as a page in sight would (`AgentAwake`).
    @discardableResult
    func open(_ url: URL) -> Tab {
        let tab = browser.open(url, inBackground: true)
        tab.isKeptAwake = true
        tab.page?.hearsWindowCovered(false)
        return tab
    }

    func close(_ id: Tab.ID) {
        browser.close(id)
    }

    /// The awake tabs' pages but those watched in the window now, as when
    /// a window of the owner's lets one go.
    func holdPagesNow() {
        window.hold(browser.tabs.filter { !$0.isAsleep && !watched.contains($0.id) }.compactMap(\.page))
    }

    /// Every tab closed and the window let go of.
    func close() {
        browser.closeAll()
        window.hold([])
        window.close()
    }

    /// The awake tabs' pages in the window, as tabs open, close, sleep and
    /// wake, and as the owner stops watching one: a page in no window is
    /// one WebKit treats as hidden.
    private func holdPages() {
        withObservationTracking {
            holdPagesNow()
        } onChange: { [weak self] in
            Task { @MainActor in self?.holdPages() }
        }
    }
}

/// The window Agent tabs' pages are in: borderless, parked off every
/// screen, one level below normal windows, never key and never ordered
/// front, so nothing an agent does comes before the owner or takes their
/// keyboard. In the window server all the same, so its pages draw and run.
/// Not one of the owner's windows (`BrowserWindow`): no Window menu, no ⌘`,
/// no Mission Control, no list of windows.
final class AgentWindow: NSWindow {
    /// The size of an Agent tab's page: a laptop's window.
    static let size = NSSize(width: 1280, height: 800)

    private var screensChanged: NSObjectProtocol?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hasShadow = false
        animationBehavior = .none
        contentView = NSView(frame: NSRect(origin: .zero, size: Self.size))
        park()
        screensChanged = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.park() }
        }
        super.orderBack(nil)
    }

    isolated deinit {
        if let screensChanged { NotificationCenter.default.removeObserver(screensChanged) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Never in front: asked to come forward, it goes to the back of its level.
    override func makeKeyAndOrderFront(_ sender: Any?) { orderBack(sender) }
    override func orderFront(_ sender: Any?) { orderBack(sender) }
    override func orderFrontRegardless() { orderBack(nil) }

    /// AppKit would bring a window back onto a screen; this one stays off.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Off screen again, to the left of every screen there is now.
    func park() {
        setFrameOrigin(Self.parking(beside: NSScreen.screens.map(\.frame), size: frame.size))
    }

    /// Where a window of `size` touches none of `screens`: left of them all,
    /// with a gap, level with the lowest.
    nonisolated static func parking(beside screens: [NSRect], size: NSSize) -> NSPoint {
        let all = screens.reduce(NSRect.null) { $0.union($1) }
        let bounds = all.isNull ? .zero : all
        return NSPoint(x: bounds.minX - size.width - 100, y: bounds.minY)
    }

    /// Exactly `pages` in the window, each filling it, one over another.
    func hold(_ pages: [WKWebView]) {
        guard let content = contentView else { return }
        let wanted = Set(pages.map(ObjectIdentifier.init))
        for case let page as WKWebView in content.subviews where !wanted.contains(ObjectIdentifier(page)) {
            page.removeFromSuperview()
        }
        for page in pages where page.superview !== content {
            page.removeFromSuperview()
            page.frame = content.bounds
            page.autoresizingMask = [.width, .height]
            content.addSubview(page)
        }
    }
}
