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
    // Off screen, drawn into a picture only.
    let window = BrowserWindow(browser: browser)
    defer { window.close() }
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
    // In points from the top left, as the window is laid out.
    let colour = { (x: CGFloat, y: CGFloat) in bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)) }
    // Just under the bar's top edge, clear of its controls: between the
    // window's buttons, and halfway across the bar.
    let y = BrowserView.margin + 2
    let underButtons = try #require(colour(BrowserView.trafficLightsWidth / 2, y))
    let bar = try #require(colour(content.bounds.width / 2, y))
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
/// been pressed; Tab then goes on into the controls.
@MainActor
@Test func aWindowDoesntPutTheKeyboardOnItsFirstButton() throws {
    // Off screen: a window ordered in would take part in other tests' focus.
    let window = BrowserWindow(browser: Browser(dataStore: .nonPersistent()))
    defer { window.close() }
    let rest = try #require(window.initialFirstResponder as? KeyboardRest)
    #expect(!rest.canBecomeKeyView)
    #expect(window.makeFirstResponder(rest))
    window.selectNextKeyView(nil)
    #expect(window.firstResponder !== rest)
}
