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

/// ⌘N goes to the window of the profile in front; from an incognito window,
/// or with none in front, to the profile used last, else Personal.
@MainActor
@Test func newWindowGoesToTheProfileInFront() {
    let root = FileManager.default.temporaryDirectory.appending(path: "nerda-menu-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let work = Profile(name: "Work", symbol: "briefcase", color: .blue, root: root)
    let personal = Browser()
    let workBrowser = Browser(profile: work)
    let incognito = Browser(dataStore: .nonPersistent())
    #expect(AppMenu.newWindowProfile(front: workBrowser, lastUsed: personal) === work)
    #expect(AppMenu.newWindowProfile(front: incognito, lastUsed: workBrowser) === work)
    #expect(AppMenu.newWindowProfile(front: nil, lastUsed: workBrowser) === work)
    #expect(AppMenu.newWindowProfile(front: nil, lastUsed: nil).isMain)
    #expect(AppMenu.newWindowProfile(front: personal, lastUsed: workBrowser).isMain)
}

/// Every item of the menu bar, in its submenus too.
@MainActor
private func items(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
}

/// No two of the menu bar's items answer to the same key, and Downloads and
/// the Vault have the keys Safari and Chrome give Downloads.
@MainActor
@Test func menuKeysAreEachTheirOwn() {
    let menu = AppMenu(browser: Browser()).bar()
    let keyed = items(of: menu).filter { !$0.keyEquivalent.isEmpty }
    var seen: [String: String] = [:]
    for item in keyed {
        let key = "\(item.keyEquivalentModifierMask.rawValue) \(item.keyEquivalent)"
        #expect(seen[key] == nil, "\(item.title) has the key of \(seen[key] ?? "")")
        seen[key] = item.title
    }
    let downloads = keyed.first { $0.title == "Downloads" }
    #expect(downloads?.keyEquivalent == "l" && downloads?.keyEquivalentModifierMask == [.command, .option])
    let vault = keyed.first { $0.title == "Vault" }
    #expect(vault?.keyEquivalent == "p" && vault?.keyEquivalentModifierMask == [.command, .option])
}
