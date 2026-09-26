import AppKit
import WebKit

/// A page that goes back and forward with two fingers the way Chrome does:
/// swiping sideways past the page's edge pulls an arrow in from that side,
/// and letting go once it has filled goes there. WebKit's own swipe drags the
/// whole page aside instead, over a snapshot of the page it goes to.
final class SwipingWebView: WKWebView {
    /// The swipe under way, from fingers down to fingers up.
    private var swipe: Swipe?
    /// How far the fingers have gone since they came down, until it's clear
    /// whether they're going sideways (a swipe) or up and down (a scroll).
    private var opening: CGSize?
    private let arrow = SwipeArrow()

    private struct Swipe {
        /// Toward the previous page (fingers moving right) or the next.
        let back: Bool
        /// How far the fingers have gone that way.
        var distance: CGFloat = 0
        /// Whether what's under the pointer scrolls that way itself, which
        /// makes the swipe the page's; nil until the page has said.
        var pageScrolls: Bool?
        /// When it set off, for a flick, and for a page slow to say.
        let began = Date.now

        var armed: Bool { pageScrolls == false && distance >= SwipingWebView.reach }
        /// Short of `reach`, but quick: a flick goes too, as in Safari.
        var flicked: Bool {
            pageScrolls == false && distance >= SwipingWebView.flick
                && Date.now.timeIntervalSince(began) <= SwipingWebView.flickTime
        }
    }

    /// How far the fingers go before letting go goes to the page. Safari's
    /// distance, about: at 120 going back took a long reach across the trackpad.
    private static let reach: CGFloat = 70
    /// A flick: at least this far, let go within `flickTime` of setting off.
    private static let flick: CGFloat = 30
    private static let flickTime: TimeInterval = 0.25
    /// How long the page has to say whether the swipe is its own. One that
    /// can't say in time (busy, or stuck) can still be left by hand.
    private static let patience: TimeInterval = 0.18

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        arrow.alphaValue = 0
        addSubview(arrow)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Esc the page had no use for. AppKit would take a full-screen window out
    /// of full screen for it; browsers don't (a page's video is taken out by
    /// the page, see Fullscreen), so it goes no further.
    override func cancelOperation(_ sender: Any?) {}

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        incognitoAsked = nil
        // Under a link's Open Link in New Window, outside incognito: the same
        // item, whose window (Browser's createWebViewWith) goes to incognito.
        if configuration.websiteDataStore.isPersistent,
           let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            let item = NSMenuItem(title: "Open Link in Incognito Window", action: #selector(openInIncognito(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = menu.items[index]
            menu.insertItem(item, at: index + 1)
        }
        let added = Extensions.shared.menuItems(for: self)
        if !added.isEmpty {
            menu.addItem(.separator())
            added.forEach(menu.addItem)
        }
        guard Screenshot.isOn else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Screenshot", action: #selector(copyScreenshot), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save Screenshot…", action: #selector(saveScreenshot), keyEquivalent: "").target = self
    }

    /// When Open Link in Incognito Window was picked, until the window the
    /// link asks for comes (see `takeIncognitoAsk`).
    private var incognitoAsked: Date?

    @objc private func openInIncognito(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? NSMenuItem, let action = original.action else { return }
        incognitoAsked = .now
        NSApp.sendAction(action, to: original.target, from: original)
    }

    /// Whether the window this page asks for now is the link picked for
    /// incognito. Only just after it was picked: a window the page opens
    /// later of its own accord is an ordinary one.
    func takeIncognitoAsk() -> Bool {
        defer { incognitoAsked = nil }
        return incognitoAsked.map { Date.now.timeIntervalSince($0) < 2 } ?? false
    }

    @objc private func copyScreenshot() { Screenshot.copy(self) }
    @objc private func saveScreenshot() { Screenshot.save(self) }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // A mouse wheel, or the glide after the fingers lift, doesn't swipe.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        // Positive when the fingers move right, whichever way scrolling goes.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX

        switch event.phase {
        case .began:
            end(going: false)
            opening = .zero
        case .ended:
            stopWaiting()
            return end(going: swipe.map { $0.armed || $0.flicked } ?? false)
        case .cancelled:
            return end(going: false)
        default:
            break
        }

        if var moved = opening {
            moved.width += dx
            moved.height += event.scrollingDeltaY
            opening = moved
            // A few points in, the fingers have shown which way they mean to
            // go: only a clearly sideways swipe is one, not a scroll drifting.
            guard abs(moved.width) + abs(moved.height) > 6 else { return }
            opening = nil
            let back = moved.width > 0
            guard abs(moved.width) > abs(moved.height) * 1.3, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  back ? canGoBack : canGoForward
            else { return }
            swipe = Swipe(back: back, distance: abs(moved.width))
            ask(back: back, at: convert(event.locationInWindow, from: nil))
        } else if let current = swipe {
            swipe?.distance = max(0, current.distance + (current.back ? dx : -dx))
            stopWaiting()
        }
        showArrow()
    }

    /// A page that hasn't said in time whether the swipe is its own is taken
    /// to have nothing to scroll that way.
    private func stopWaiting() {
        guard let swipe, swipe.pageScrolls == nil, Date.now.timeIntervalSince(swipe.began) > Self.patience else { return }
        self.swipe?.pageScrolls = false
    }

    /// Three fingers sideways, when the trackpad is set to swipe between pages
    /// with them, and Logi Options+, which sends a mouse's back and forward
    /// buttons this way: positive to go back, as Safari and Chrome read it.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, canGoBack { goBack() } else if event.deltaX < 0, canGoForward { goForward() } else { super.swipe(with: event) }
    }

    /// A mouse's back and forward buttons: buttons 3 and 4, as mice send them.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where canGoBack: goBack()
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    /// Asks the page whether what's under the pointer can scroll that way
    /// itself (a carousel, a wide table), as Chrome leaves such a swipe to the page.
    // ponytail: frames from another site answer for their whole box, not what's inside.
    private func ask(back: Bool, at point: CGPoint) {
        let scale = pageZoom
        let arguments: [String: Any] = [
            "x": point.x / scale, "y": point.y / scale, "back": back,
        ]
        Task {
            let scrolls = try? await callAsyncJavaScript(Self.scrollsThere, arguments: arguments, contentWorld: .defaultClient)
            // A page that can't say (a PDF) has nothing of its own to scroll.
            guard swipe?.back == back, swipe?.pageScrolls == nil else { return }
            swipe?.pageScrolls = scrolls as? Bool ?? false
            showArrow()
        }
    }

    private func end(going: Bool) {
        opening = nil
        guard let swipe else { return }
        self.swipe = nil
        if going { _ = swipe.back ? goBack() : goForward() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            arrow.animator().alphaValue = 0
        }
    }

    private func showArrow() {
        guard let swipe, swipe.pageScrolls == false else { return }
        let size = SwipeArrow.size
        // From just out of sight to a little way in.
        let offset = -size + (size + 16) * min(swipe.distance / Self.reach, 1)
        let x = swipe.back ? offset : bounds.width - size - offset
        arrow.frame = CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        arrow.back = swipe.back
        // A firm tap through the trackpad the moment letting go comes to go
        // there, and a light one as it stops doing so, to know without looking
        // (the trackpad only taps fingers that are on it, so not on letting
        // go). Hidden means a fresh swipe, whatever the last one left the arrow at.
        let wasArmed = arrow.armed && arrow.alphaValue > 0
        if swipe.armed != wasArmed {
            NSHapticFeedbackManager.defaultPerformer.perform(swipe.armed ? .levelChange : .alignment, performanceTime: .now)
        }
        arrow.armed = swipe.armed
        arrow.alphaValue = 1
    }

    private static let scrollsThere = """
        const scrolls = (box, style) => {
            const room = box.scrollWidth - box.clientWidth;
            if (room < 1) return false;
            const left = style.direction === 'rtl' ? room + box.scrollLeft : box.scrollLeft;
            return back ? left > 0.5 : left < room - 0.5;
        };
        for (let box = document.elementFromPoint(x, y); box; box = box.parentElement) {
            const style = getComputedStyle(box);
            if (/auto|scroll/.test(style.overflowX) && scrolls(box, style)) return true;
        }
        const root = document.scrollingElement;
        if (!root || [document.documentElement, document.body].some(
            box => box && /hidden|clip/.test(getComputedStyle(box).overflowX))) return false;
        return scrolls(root, getComputedStyle(root));
        """
}

/// The arrow a swipe pulls in: a round button that fills with the accent
/// colour once letting go would go.
private final class SwipeArrow: NSView {
    static let size: CGFloat = 36
    private let icon = NSImageView()

    var back = true {
        didSet {
            guard back != oldValue else { return }
            icon.image = NSImage(systemSymbolName: back ? "arrow.left" : "arrow.right", accessibilityDescription: nil)
        }
    }

    var armed = false {
        didSet {
            guard armed != oldValue else { return }
            icon.contentTintColor = armed ? .white : .labelColor
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        self.shadow = shadow
        icon.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    // Here, so the colours are the ones for the window's appearance.
    override func updateLayer() {
        layer?.backgroundColor = (armed ? NSColor.controlAccentColor : .windowBackgroundColor).cgColor
    }

    // Clicks go through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
