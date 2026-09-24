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

        var armed: Bool { pageScrolls == false && distance >= SwipingWebView.reach }
    }

    /// How far the fingers go before letting go goes to the page.
    private static let reach: CGFloat = 120

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        arrow.alphaValue = 0
        addSubview(arrow)
    }

    required init?(coder: NSCoder) { fatalError() }

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
            return end(going: swipe?.armed == true)
        case .cancelled:
            return end(going: false)
        default:
            break
        }

        if var moved = opening {
            moved.width += dx
            moved.height += event.scrollingDeltaY
            opening = moved
            guard hypot(moved.width, moved.height) > 3 else { return }
            opening = nil
            let back = moved.width > 0
            guard abs(moved.width) > abs(moved.height), NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  back ? canGoBack : canGoForward
            else { return }
            swipe = Swipe(back: back, distance: abs(moved.width))
            ask(back: back, at: convert(event.locationInWindow, from: nil))
        } else if let current = swipe {
            swipe?.distance = max(0, current.distance + (current.back ? dx : -dx))
        }
        showArrow()
    }

    /// Asks the page whether what's under the pointer can scroll that way
    /// itself (a carousel, a wide table), as Chrome leaves such a swipe to the page.
    // ponytail: frames from another site answer for their whole box, not what's inside.
    private func ask(back: Bool, at point: CGPoint) {
        let scale = pageZoom
        let arguments: [String: Any] = [
            "x": (point.x - coveredLeading) / scale, "y": point.y / scale, "back": back,
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
        let x = swipe.back ? coveredLeading + offset : bounds.width - size - offset
        arrow.frame = CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        arrow.back = swipe.back
        arrow.armed = swipe.armed
        arrow.alphaValue = 1
    }

    /// The part of the page's left side the sidebar lies over.
    private var coveredLeading: CGFloat {
        if #available(macOS 26, *) { obscuredContentInsets.left } else { 0 }
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
