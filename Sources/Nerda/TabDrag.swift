import AppKit
import SwiftUI

/// A tab dragged off its list, as Safari and Chrome tear one off: its place
/// there closes up (a pinned site's tile stays, faded, as only its page goes),
/// and a card of it follows the pointer across windows and displays. Over the
/// tabs of another window of the same browsing, a gap opens where it would
/// land, the tab already in it, and the card makes way for it. Let go there,
/// it joins that window; anywhere else, it gets a window of its own on the
/// display under the pointer. Back over its own list, it is reordered as before.
@Observable
final class TabDrag {
    static let shared = TabDrag()

    /// The tab off its list.
    private(set) var detached: Tab.ID?
    /// The window under the pointer that would take it, and the pointer in
    /// that window's content, from its top left (SwiftUI's global space).
    private(set) var target: Browser?
    private(set) var point: CGPoint?
    /// Where the window under the pointer would put it among its tabs, as its
    /// list works it out (`IncomingWatch`): none while it is off the list.
    @ObservationIgnored var index: Int? {
        didSet { if index != oldValue { placeCard() } }
    }
    /// The tab dragged, for the gap to show it.
    @ObservationIgnored private(set) weak var tab: Tab?
    @ObservationIgnored private var mouse = NSPoint.zero
    @ObservationIgnored private var card: NSPanel?
    @ObservationIgnored private var cardView: NSHostingView<AnyView>?

    /// The pointer on the screen, from where it is in `browser`'s window's
    /// content (from its top left). Worked out from the drag rather than read
    /// from the pointer, so it is where the drag says, step by step.
    static func screen(_ point: CGPoint, in browser: Browser) -> NSPoint {
        guard let window = browser.window else { return NSEvent.mouseLocation }
        let height = window.contentView?.frame.height ?? 0
        return window.convertPoint(toScreen: NSPoint(x: point.x, y: height - point.y))
    }

    /// A step of a tab's drag, the pointer at `mouse` on the screen;
    /// `outside`, it is off the tab's list.
    func moved(_ id: Tab.ID, in browser: Browser, outside: Bool, at mouse: NSPoint) {
        guard let tab = browser.tabs.first(where: { $0.id == id }) else { return }
        if self.tab !== tab { start(tab, from: browser) }
        self.mouse = mouse
        let off = outside ? id : nil
        if off != detached {
            withAnimation(.snappy(duration: 0.2)) { detached = off }
            // Taken now, not as the drag began: the press brings the tab on
            // screen, and its page isn't drawn yet then.
            if off != nil { takeLook(of: tab) }
        }
        let under = outside ? window(at: mouse, taking: browser) : nil
        if under?.browser !== target {
            target = under?.browser
            index = nil
        }
        point = under.map { window in
            let inside = window.convertPoint(fromScreen: mouse)
            return CGPoint(x: inside.x, y: (window.contentView?.frame.height ?? 0) - inside.y)
        }
        placeCard()
    }

    /// The drag let go. Off its list, the tab goes to the window under the
    /// pointer, into its gap, or to a window of its own: true. On its list,
    /// false, for the list to place it.
    func ended(_ id: Tab.ID, in browser: Browser, at mouse: NSPoint) -> Bool {
        let off = detached == id, target = target, index = index
        tab = nil
        detached = nil
        self.target = nil
        point = nil
        self.index = nil
        card?.orderOut(nil)
        cardView?.rootView = AnyView(EmptyView())
        guard off else { return false }
        if let target {
            withAnimation(.slide) { browser.move(id, to: target, at: index) }
            target.window?.makeKeyAndOrderFront(nil)
        } else {
            Windows.moveToNewWindow(id, from: browser, on: NSScreen.screens.first { $0.frame.contains(mouse) })
        }
        return true
    }

    /// The card made for `tab`, its page's picture added once taken.
    private func start(_ tab: Tab, from browser: Browser) {
        self.tab = tab
        let card = card ?? makeCard()
        card.appearance = browser.window?.effectiveAppearance
        show(tab, look: tab.look)
    }

    private func takeLook(of tab: Tab) {
        Task { [weak self, weak tab] in
            guard let tab, let look = await tab.snapshot() else { return }
            if self?.tab === tab { self?.show(tab, look: look) }
        }
    }

    private func show(_ tab: Tab, look: NSImage?) {
        // Room round the card for its shadow.
        cardView?.rootView = AnyView(TabPeek(tab: tab, look: look).padding(16))
        if let size = cardView?.fittingSize { card?.setContentSize(size) }
        placeCard()
    }

    /// Under the pointer, hanging from it, while off the list and not in a
    /// gap, where the tab itself shows.
    private func placeCard() {
        guard let card else { return }
        guard detached != nil, index == nil else { return card.orderOut(nil) }
        let size = card.frame.size
        card.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 8 - size.height))
        if !card.isVisible { card.orderFront(nil) }
    }

    private func makeCard() -> NSPanel {
        let card = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false
        card.ignoresMouseEvents = true
        card.level = .floating
        card.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        card.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        card.contentView = view
        self.card = card
        cardView = view
        return card
    }

    /// The window in front under `point` that can take a tab of `browser`'s:
    /// another of the same browsing, not locked.
    private func window(at point: NSPoint, taking browser: Browser) -> BrowserWindow? {
        let under = NSApp.orderedWindows.first { $0 !== card && $0.isVisible && $0.frame.contains(point) } as? BrowserWindow
        guard let under, under.browser !== browser, under.browser.dataStore === browser.dataStore,
              !under.browser.locked else { return nil }
        return under
    }
}

/// Where a tab dragged from another window over this one would land among
/// its tabs (`locate`, from the pointer in the window's content), drawing
/// nothing: a view of its own, so each move of the pointer has only this
/// worked out again, and the list drawn again only when the place changes.
struct IncomingWatch: View {
    let browser: Browser
    @Binding var index: Int?
    let locate: (CGPoint) -> Int?

    var body: some View {
        let drag = TabDrag.shared
        let point = drag.target === browser ? drag.point : nil
        Color.clear.onChange(of: point) { _, point in
            let found = point.flatMap(locate)
            if found != index { index = found }
            if drag.target === browser { drag.index = found }
        }
    }
}

