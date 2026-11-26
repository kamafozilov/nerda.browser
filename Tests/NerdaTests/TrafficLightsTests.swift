import AppKit
import SwiftUI
import Testing
@testable import Nerda

/// The window's buttons are always there, the sidebar put away included:
/// no pointer up in the title bar needed, and they don't go after a while.
@MainActor
@Test func theWindowButtonsStayWithTheSidebarPutAway() async throws {
    let suite = "dev.nerda.tests.trafficLights.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let before = WindowFrame.defaults
    WindowFrame.defaults = defaults
    defer {
        WindowFrame.defaults = before
        defaults.removePersistentDomain(forName: suite)
    }
    // Incognito, so links other tests open from other apps never come to
    // this window (`Windows.lastUsed` passes over incognito ones).
    let browser = Browser(dataStore: .nonPersistent())
    browser.sidebarOpen = false
    let window = BrowserWindow(browser: browser)
    window.orderBack(nil)
    defer { window.close() }
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
    #expect(buttons.count == 3)
    // Shown, and so clickable; and not faded out.
    let shown = { buttons.allSatisfy { !$0.isHidden && $0.alphaValue == 1 } }

    // Long enough for the window to have been laid out and drawn, and for
    // anything that would put them away after a while to have done so.
    try await Task.sleep(for: .seconds(1))
    #expect(shown())
    #expect(!browser.sidebarOpen)

    // Brought out and put away again, they stay all the while.
    browser.toggleSidebar()
    try await Task.sleep(for: .milliseconds(500))
    #expect(shown())
    browser.toggleSidebar()
    try await Task.sleep(for: .milliseconds(500))
    #expect(shown())
}

/// With the sidebar put away, the address bar's own ground runs under the
/// window's buttons, up to the card's left edge, so the top left of the
/// window is one with the bar rather than a block of the window's glass;
/// the bar's buttons start past the window's, so they never sit over them.
@MainActor
@Test(arguments: [false, true])
func theAddressBarRunsUnderTheWindowButtons(incognito: Bool) throws {
    let browser = incognito ? Browser(dataStore: .nonPersistent()) : Browser()
    browser.sidebarOpen = false
    // Off screen, drawn into a picture only, and only the row looked at: the
    // whole window, as big as the screen, holds the main thread up for a
    // second, and every other test with it.
    let window = BrowserWindow(browser: browser)
    defer { window.close() }
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    // Just under the bar's top edge, clear of its controls: between the
    // window's buttons, and halfway across the bar. In points from the top
    // left, as the window is laid out.
    let y = BrowserView.margin + 2
    let row = CGRect(x: 0, y: y, width: content.bounds.width, height: 1)
    let drawn = content.isFlipped ? row : CGRect(x: 0, y: content.bounds.height - row.maxY, width: row.width, height: 1)
    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: drawn))
    content.cacheDisplay(in: drawn, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / row.width
    let colour = { (x: CGFloat) in bitmap.colorAt(x: Int(x * scale), y: 0) }
    let underButtons = try #require(colour(BrowserView.trafficLightsWidth / 2))
    let bar = try #require(colour(content.bounds.width / 2))
    #expect(underButtons == bar, "\(underButtons) under the buttons, \(bar) on the bar")
}

/// With the sidebar put away, the address bar's buttons start past where
/// the window's buttons are, so they never sit over them.
@MainActor
@Test func theAddressBarLeavesRoomForTheWindowButtons() throws {
    let window = BrowserWindow(browser: Browser(dataStore: .nonPersistent()))
    defer { window.close() }
    let zoom = try #require(window.standardWindowButton(.zoomButton))
    let right = zoom.convert(zoom.bounds, to: nil).maxX
    #expect(right > 0)
    #expect(right + 4 <= BrowserView.trafficLightsWidth)
}

/// Opened with nothing to type into (a settings page), the window keeps the
/// keyboard to itself rather than ring its first button, as though Tab had
/// been pressed; Tab then goes on into the controls. With Keyboard
/// navigation on, as only then does Tab go to buttons, whatever this Mac's.
@MainActor
@Test func aWindowDoesntPutTheKeyboardOnItsFirstButton() throws {
    try withKeyboardNavigation {
        // Off screen: a window ordered in would take part in other tests' focus.
        let window = BrowserWindow(browser: Browser(dataStore: .nonPersistent()))
        defer { window.close() }
        let rest = try #require(window.initialFirstResponder as? KeyboardRest)
        #expect(!rest.canBecomeKeyView)
        #expect(window.makeFirstResponder(rest))
        window.selectNextKeyView(nil)
        #expect(window.firstResponder !== rest)
    }
}

/// Holds an animation at one point of its way for a few seconds, the slide
/// drawn as it is at that moment, then ends it: one held for good would
/// keep the window drawing long after it closed, and slow the other tests.
private struct Held: CustomAnimation {
    let fraction: Double
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        time < 3 ? value.scaled(by: fraction) : nil
    }
}

/// Putting the sidebar away and bringing it back moves one edge, the
/// card's left one, and nothing else changes on the way: at every moment
/// the address bar's row is the window's glass up to that edge, and the
/// bar's own ground from it on, as far as the card goes. No patch of
/// another colour, no ground that fades or is switched, no second edge. The
/// slide is held at points along its way and drawn off screen, in an
/// incognito and a regular window, one at a time. The window's view is drawn
/// in a small plain window of its own, which other tests, looking for
/// browser windows, don't count.
@MainActor
@Test(.serialized, arguments: [(false, true), (true, true), (false, false), (true, false)], [0.1, 0.3, 0.5, 0.7, 0.9])
func theCardHasOneEdgeAsTheSidebarSlides(way: (coming: Bool, incognito: Bool), fraction: Double) async throws {
    let coming = way.coming
    let browser = way.incognito ? Browser(dataStore: .nonPersistent()) : Browser()
    browser.sidebarOpen = !coming
    // The sidebar's width in settings of the test's own, not the run's
    // (shared with the other tests and another run beside this one).
    let suite = "dev.nerda.tests.cardEdge.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sidebar = Sidebar.defaultWidth + 30
    defaults.set(sidebar, forKey: "sidebarWidth")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = true
    // With Reduce Motion off, whatever this Mac's: with it on, the sidebar
    // fades where it is rather than slide with the card.
    let content = NSHostingView(rootView: BrowserView(browser: browser, window: window)
        .environment(\.incognito, browser.isPrivate)
        .environment(\.motionReduced, false)
        .defaultAppStorage(defaults))
    window.contentView = content
    defer { window.close() }

    // Where the card's left edge is at this point of the slide.
    let margin = BrowserView.margin
    let start = coming ? margin : sidebar
    let edge = coming ? margin + (sidebar - margin) * fraction : sidebar + (margin - sidebar) * fraction

    // A line along the bar's row, under its buttons and above its hairline,
    // where nothing but its ground is drawn; the sidebar's top row has
    // nothing there either.
    let line = CGRect(x: 0, y: margin + AddressBar.height - 4, width: content.bounds.width, height: 1)
    let drawn = content.isFlipped ? line
        : CGRect(x: line.minX, y: content.bounds.height - line.maxY, width: line.width, height: line.height)
    let alike = { (a: NSColor, b: NSColor) in
        abs(a.redComponent - b.redComponent) <= 0.01 && abs(a.greenComponent - b.greenComponent) <= 0.01
            && abs(a.blueComponent - b.blueComponent) <= 0.01 && abs(a.alphaComponent - b.alphaComponent) <= 0.01
    }
    /// What is wrong along the line as it is drawn now: none, when it is
    /// glass up to the edge and the bar from it on. A point or two either
    /// side of the edge is its hairline and the rounding of the pixels.
    let look = { (edge: CGFloat) throws -> [String] in
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: drawn))
        content.cacheDisplay(in: drawn, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / line.width
        let colour = { (x: CGFloat) in bitmap.colorAt(x: Int(x * scale), y: 0)?.usingColorSpace(.sRGB) }
        // The bar's ground, far from the edge, and the glass, in the window's margin.
        let bar = try #require(colour(content.bounds.width - margin - 40))
        let glass = try #require(colour(2))
        try #require(!alike(bar, glass), "the bar's ground and the glass are drawn alike here: \(bar)")
        var wrong: [String] = []
        for x in stride(from: CGFloat(1), to: content.bounds.width - margin - 2, by: 1) where abs(x - edge) > 2 {
            guard let here = colour(x) else { continue }
            if x < edge, !alike(here, glass) { wrong.append("\(x): \(here), not the glass") }
            if x > edge, !alike(here, bar) { wrong.append("\(x): \(here), not the bar") }
        }
        return wrong
    }
    // Drawn as it starts, the card's edge where the sidebar leaves it.
    var before: [String] = []
    try await waitFor("drawn as it starts, with the card's edge at \(start): \(before.prefix(3))") {
        before = try look(start)
        return before.isEmpty
    }

    withAnimation(Animation(Held(fraction: fraction))) { browser.sidebarOpen = coming }

    // Looked at until the slide is drawn where it is held: with the other
    // tests running, that takes the window a moment longer at times.
    var wrong = try look(edge)
    for _ in 0..<40 where !wrong.isEmpty {
        try await Task.sleep(for: .milliseconds(50))
        wrong = try look(edge)
    }
    #expect(wrong.isEmpty, "with the card's edge at \(edge): \(wrong.count) points, e.g. \(wrong.prefix(3))")
}
