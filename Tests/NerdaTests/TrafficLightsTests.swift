import AppKit
import SwiftUI
import Testing
@testable import Nerda

/// The first view of `type` under `view`.
@MainActor
private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let view = view as? T { return view }
    return view.subviews.lazy.compactMap { find(type, in: $0) }.first
}

/// With the sidebar put away, the window's buttons come while the pointer is
/// up in the title bar, all along it, and go once it leaves; what tells that
/// takes no clicks from the address bar under it.
@MainActor
@Test func theWindowButtonsComeWithThePointerAtTheTop() async throws {
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
    let close = try #require(window.standardWindowButton(.closeButton))
    // Shown, and so clickable, at once; its fade in is drawn only as the
    // screen is, which a busy or sleeping display may not do within the test.
    let shown = { !close.isHidden }

    try await waitFor { close.isHidden }
    #expect(close.isHidden)

    let content = try #require(window.contentView)
    let tracker = try #require(find(TitleBarHover.Tracker.self, in: content))
    #expect(tracker.titleBar.height > 0)
    #expect(tracker.titleBar.height == window.frame.height - window.contentLayoutRect.height)
    #expect(tracker.titleBar.width == tracker.bounds.width)
    #expect(tracker.hitTest(NSPoint(x: tracker.titleBar.midX, y: tracker.titleBar.midY)) == nil)

    let event = { (type: NSEvent.EventType) in
        NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               trackingNumber: 0, userData: nil)!
    }
    tracker.mouseEntered(with: event(.mouseEntered))
    try await waitFor { shown() }
    #expect(shown())
    // The sidebar stays put away.
    #expect(!browser.sidebarOpen)

    tracker.mouseExited(with: event(.mouseExited))
    try await waitFor { close.isHidden }
    #expect(close.isHidden)
}
