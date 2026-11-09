import AppKit
import Testing
@testable import Nerda

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
private let second = CGRect(x: 1512, y: 0, width: 2560, height: 1415)

/// The first time, and when it was left filling the screen, it fills it.
@MainActor
@Test func aWindowFillsTheScreenTheFirstTime() {
    #expect(WindowFrame.place(nil, on: [screen]) == WindowFrame(frame: screen, fills: true))
    let left = WindowFrame(frame: CGRect(x: 0, y: 0, width: 1512, height: 900), fills: true)
    #expect(WindowFrame.place(left, on: [screen]) == WindowFrame(frame: screen, fills: true))
}

/// Left smaller, it opens where and at the size it was left, on whichever
/// display that was.
@MainActor
@Test func aWindowOpensWhereItWasLeft() {
    let left = WindowFrame(frame: CGRect(x: 1700, y: 200, width: 1200, height: 800), fills: false)
    #expect(WindowFrame.place(left, on: [screen, second]) == left)
    let filling = WindowFrame(frame: CGRect(x: 1600, y: 100, width: 900, height: 600), fills: true)
    #expect(WindowFrame.place(filling, on: [screen, second]) == WindowFrame(frame: second, fills: true))
}

/// Left on a display since unplugged, or bigger than the one it is on now,
/// it fills the screen; partly off it, it comes back all on it.
@MainActor
@Test func aWindowLeftWhereItNoLongerFitsFillsTheScreen() {
    let gone = WindowFrame(frame: CGRect(x: 1700, y: 200, width: 1200, height: 800), fills: false)
    #expect(WindowFrame.place(gone, on: [screen]) == WindowFrame(frame: screen, fills: true))
    let big = WindowFrame(frame: CGRect(x: 0, y: 0, width: 2400, height: 800), fills: false)
    #expect(WindowFrame.place(big, on: [screen, second]) == WindowFrame(frame: screen, fills: true))
    let off = WindowFrame(frame: CGRect(x: 1000, y: -100, width: 800, height: 600), fills: false)
    #expect(WindowFrame.place(off, on: [screen]) == WindowFrame(frame: CGRect(x: 712, y: 0, width: 800, height: 600), fills: false))
}

/// An incognito window over the regular one opens down and to its right.
@MainActor
@Test func anIncognitoWindowCascadesPastTheRegularOne() {
    let regular = CGRect(x: 100, y: 100, width: 1000, height: 700)
    let placed = WindowFrame(frame: regular, fills: false).cascaded(past: [regular])
    #expect(placed.frame == CGRect(x: 122, y: 78, width: 1000, height: 700))
    #expect(WindowFrame(frame: screen, fills: true).cascaded(past: [screen]).frame == screen)
}

/// The regular window keeps the frame it is moved or resized to, but not
/// one it is in full screen at, and an incognito one opens there too.
@MainActor
@Test func theWindowRemembersItsFrame() throws {
    let suite = "dev.nerda.tests.windowFrame.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let before = WindowFrame.defaults
    WindowFrame.defaults = defaults
    defer {
        WindowFrame.defaults = before
        defaults.removePersistentDomain(forName: suite)
    }
    let visible = try #require(NSScreen.main?.visibleFrame)
    let frame = CGRect(x: visible.minX + 40, y: visible.minY + 30, width: 900, height: 620)

    let window = BrowserWindow(browser: Browser())
    #expect(window.frame == visible)
    window.setFrame(frame, display: false)
    window.close()
    #expect(WindowFrame.saved(for: Profile.mainID) == WindowFrame(frame: frame, fills: false))

    let again = BrowserWindow(browser: Browser())
    defer { again.close() }
    #expect(again.frame == frame)

    let incognito = BrowserWindow(browser: Browser(dataStore: .nonPersistent()))
    defer { incognito.close() }
    #expect(incognito.frame.size == frame.size)
    incognito.setFrame(visible, display: false)
    #expect(WindowFrame.saved(for: Profile.mainID)?.frame == frame)
}
