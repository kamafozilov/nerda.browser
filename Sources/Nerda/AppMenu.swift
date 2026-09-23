import AppKit

/// The menu bar. Besides listing what the app can do, it is how the standard
/// shortcuts work at all: ⌘A, ⌘C, ⌘V, ⌘Z and the rest are the Edit menu's
/// items, sent down the responder chain to whatever text field has focus.
final class AppMenu: NSObject {
    let browser: Browser

    init(browser: Browser) {
        self.browser = browser
    }

    func install() {
        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        let servicesMenu = submenu("Services", [])

        let bar = NSMenu()
        bar.items = [
            submenu("Nerda", [
                item("About Nerda", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                servicesMenu,
                .separator(),
                item("Hide Nerda", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
                .separator(),
                item("Quit Nerda", #selector(NSApplication.terminate(_:)), "q"),
            ]),
            submenu("File", [
                item("New Tab", #selector(newTab), "t", target: self),
                item("Close Tab", #selector(closeTab), "w", target: self),
            ]),
            submenu("Edit", [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Delete", #selector(NSText.delete(_:))),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
            ]),
            // macOS adds Enter Full Screen here by itself.
            submenu("View", [
                item("Collapse Tabs", #selector(toggleSidebar), "s", target: self),
            ]),
            windowMenu,
        ]
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.servicesMenu = servicesMenu.submenu
    }

    @objc private func newTab() { browser.showCommandBar() }
    @objc private func closeTab() { browser.closeSelectedTab() }
    @objc private func toggleSidebar() { browser.toggleSidebar() }

    private func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target  // nil: the first responder that can do it
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.items = items
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

extension AppMenu: NSMenuItemValidation {
    /// Asked each time a menu opens or a shortcut is pressed.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar):
            item.title = browser.sidebarOpen ? "Collapse Tabs" : "Show Tabs"
            return true
        case #selector(closeTab):
            return browser.selectedID != nil
        default:
            return true
        }
    }
}

/// Clicking the Dock icon with the window closed brings the same window back,
/// tabs and all, as browsers do.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }
}
