import AppKit
import SwiftUI

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
            item("Select Next Tab", #selector(nextTab), "\t", .control, target: self),
            item("Select Previous Tab", #selector(previousTab), "\t", [.control, .shift], target: self),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ] + (1...9).map { number in
            // ⌘1 to ⌘9 work without nine lines of menu for them.
            let item = item("Tab \(number)", #selector(selectTab(_:)), "\(number)", target: self)
            item.tag = number
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            return item
        })
        let servicesMenu = submenu("Services", [])
        let historyMenu = submenu("History", [
            item("Back", #selector(goBack), "[", target: self),
            item("Forward", #selector(goForward), "]", target: self),
        ])

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
                item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
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
                .separator(),
                submenu("Find", [
                    item("Find…", #selector(showFind), "f", target: self),
                    item("Find Next", #selector(findNext), "g", target: self),
                    item("Find Previous", #selector(findPrevious), "g", [.command, .shift], target: self),
                ]),
            ]),
            // macOS adds Enter Full Screen here by itself.
            submenu("View", [
                item("Collapse Tabs", #selector(toggleSidebar), "s", target: self),
                .separator(),
                item("Reload Page", #selector(reload), "r", target: self),
                .separator(),
                zoom("Zoom In", 1, "+"),
                // ⌘= as well as ⌘+: they're the same key on most keyboards.
                hidden(zoom("Zoom In", 1, "=")),
                zoom("Zoom Out", -1, "-"),
                zoom("Actual Size", 0, "0"),
            ]),
            historyMenu,
            windowMenu,
        ]
        historyMenu.submenu?.delegate = self
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.servicesMenu = servicesMenu.submenu

        // A focused page takes ⌃Tab as a key of its own, so it would never
        // reach the menu: it is caught on its way in instead.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [browser] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] else { return event }
            MainActor.assumeIsolated { browser.selectTab(after: modifiers.contains(.shift) ? -1 : 1) }
            return nil
        }
    }

    @objc private func newTab() { browser.showCommandBar() }
    @objc private func closeTab() { browser.closeSelectedTab() }
    @objc private func toggleSidebar() { browser.toggleSidebar() }
    @objc private func reload() { browser.selected?.reload() }
    @objc private func goBack() { browser.selected?.webView.goBack() }
    @objc private func goForward() { browser.selected?.webView.goForward() }
    @objc private func zoom(_ sender: NSMenuItem) { browser.selected?.zoom(sender.tag) }
    @objc private func selectTab(_ sender: NSMenuItem) { browser.selectTab(number: sender.tag) }
    @objc private func nextTab() { browser.selectTab(after: 1) }
    @objc private func previousTab() { browser.selectTab(after: -1) }

    private func zoom(_ title: String, _ step: Int, _ key: String) -> NSMenuItem {
        let item = item(title, #selector(zoom(_:)), key, target: self)
        item.tag = step
        return item
    }

    @objc private func openVisit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if browser.commandBarOpen { browser.hideCommandBar() }
        withAnimation(.slide) { browser.open(url) }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "The pages you visited will no longer be suggested as you type. Open tabs stay as they are."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { History.shared.clear() }
    }

    @objc private func showFind() { browser.showFindBar() }
    @objc private func findNext() { browser.find() }
    @objc private func findPrevious() { browser.find(backwards: true) }

    private func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

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
            return browser.commandBarOpen || browser.selectedID != nil
        case #selector(reload), #selector(zoom(_:)):
            // Actual Size only once there is a zoom to undo.
            guard let tab = browser.selected else { return false }
            return item.action != #selector(zoom(_:)) || item.tag != 0 || tab.webView.pageZoom != 1
        case #selector(showFind):
            return browser.selected != nil
        case #selector(findNext), #selector(findPrevious):
            return browser.selected != nil && !browser.findQuery.isEmpty
        case #selector(nextTab), #selector(previousTab):
            return browser.tabs.count > 1
        case #selector(goBack):
            return browser.selected?.webView.canGoBack == true
        case #selector(goForward):
            return browser.selected?.webView.canGoForward == true
        case #selector(clearHistory):
            return !History.shared.visits.isEmpty
        default:
            return true
        }
    }
}

extension AppMenu: NSMenuDelegate {
    /// Under Back and Forward, the pages visited last, as Safari lists them;
    /// each opens in a tab of its own.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > 2 { menu.removeItem(at: 2) }
        menu.addItem(.separator())
        for visit in History.shared.recent(15) {
            let title = visit.title.isEmpty ? visit.url.absoluteString : visit.title
            let item = item(title.count > 60 ? title.prefix(59) + "…" : title, #selector(openVisit(_:)), target: self)
            item.representedObject = visit.url
            if let icon = Favicons.origin(of: visit.url).flatMap({ Favicons.shared.images[$0] }) {
                item.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { icon.draw(in: $0); return true }
            }
            menu.addItem(item)
        }
        if menu.items.count > 3 { menu.addItem(.separator()) }
        menu.addItem(item("Clear History…", #selector(clearHistory), target: self))
    }
}

/// Closing the window closes its tabs; clicking the Dock icon brings the
/// window back, asking where to go, as Safari does.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window: NSWindow
    let browser: Browser

    init(window: NSWindow, browser: Browser) {
        self.window = window
        self.browser = browser
    }

    func windowWillClose(_ notification: Notification) {
        browser.closeAll()
    }

    /// The window comes back with the tabs it closed with.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            browser.restore(from: Session.file)
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { save() }

    /// Going to another app is a good moment: nothing is happening here.
    func applicationDidResignActive(_ notification: Notification) { save() }

    func save() {
        browser.saveSession()
        History.shared.save()
    }

    /// The toolbar is empty: in full screen it goes with the menu bar, rather
    /// than stay as a blank strip across the top of the page.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    // Pages don't hear the window is covered while macOS animates it in or out
    // of full screen, or their videos would pause for it, until it is in view
    // again: the animation ends a moment before the window says so.
    private var settling = false

    func windowWillEnterFullScreen(_ notification: Notification) { pages(hearCovered: false) }
    func windowWillExitFullScreen(_ notification: Notification) { pages(hearCovered: false) }
    func windowDidEnterFullScreen(_ notification: Notification) { settle() }
    func windowDidExitFullScreen(_ notification: Notification) { settle() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { settle() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { settle() }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard settling, window.occlusionState.contains(.visible) else { return }
        settling = false
        pages(hearCovered: true)
    }

    private func settle() {
        settling = true
        windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
    }

    private func pages(hearCovered: Bool) {
        for tab in browser.tabs { tab.page?.hearsWindowCovered(hearCovered) }
    }
}
