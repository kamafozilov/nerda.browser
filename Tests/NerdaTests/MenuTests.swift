import AppKit
import Testing
@testable import Nerda

/// A plain window of Nerda's own, as the Vault and Task Manager are.
@MainActor
private func ownWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
}

/// With the Vault, Task Manager or About in front, the menu's tab commands
/// (⌘W above all) go to that window, never to a browser window behind it;
/// a pop-up or panel over a browser window leaves them with that browser.
@MainActor
@Test func theMenuActsOnTheWindowInFront() {
    let browser = Browser()
    let browserWindow = BrowserWindow(browser: browser)
    defer { browserWindow.close() }
    let vault = ownWindow()
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

    guard case .browser(let front) = AppMenu.front(main: browserWindow, key: browserWindow) else { Issue.record(); return }
    #expect(front === browser)
    // The Vault, key and main.
    guard case .other(let other) = AppMenu.front(main: vault, key: vault) else { Issue.record(); return }
    #expect(other === vault)
    // About: key, while the browser's window stays the main one.
    guard case .other(let about) = AppMenu.front(main: browserWindow, key: vault) else { Issue.record(); return }
    #expect(about === vault)
    // An extension's pop-up over the browser's window.
    guard case .browser = AppMenu.front(main: browserWindow, key: panel) else { Issue.record(); return }
    guard case .none = AppMenu.front(main: nil, key: nil) else { Issue.record(); return }
}
