import AppKit
import SwiftUI
import WebKit

/// The menu bar. Besides listing what the app can do, it is how the standard
/// shortcuts work at all: ⌘A, ⌘C, ⌘V, ⌘Z and the rest are the Edit menu's
/// items, sent down the responder chain to whatever text field has focus.
final class AppMenu: NSObject {
    /// The regular window's, for when no window of Nerda's is in front.
    private let regular: Browser

    /// What the menu works on: the browser of the window in front, an
    /// incognito one's included.
    private var browser: Browser { (NSApp.mainWindow as? BrowserWindow)?.browser ?? regular }

    init(browser: Browser) {
        regular = browser
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
            item("Show All History", #selector(openHistory), "y", target: self),
        ])

        let bar = NSMenu()
        bar.items = [
            submenu("Nerda", [
                item("About Nerda", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                item("Settings…", #selector(openSettings), ",", target: self),
                // Development builds don't update themselves.
                Edition.updates
                    ? item("Check for Updates…", #selector(checkForUpdates), target: self)
                    : hidden(item("Check for Updates…", #selector(checkForUpdates), target: self)),
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
                item("New Incognito Window", #selector(newIncognitoWindow), "n", [.command, .shift], target: self),
                // ⌘⇧A, as Chrome's Search Tabs: a key sites leave to the browser,
                // where ⌘K is often a site's own.
                item("Search Tabs…", #selector(searchTabs), "a", [.command, .shift], target: self),
                item("Open Location…", #selector(openLocation), "l", target: self),
                item("Close Tab", #selector(closeTab), "w", target: self),
                item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
                .separator(),
                item("Import Passwords…", #selector(importPasswords), target: self),
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
                // ⌘⇧R, as Chrome's and Firefox's hard reload.
                item("Hard Reload Page", #selector(hardReload), "r", [.command, .shift], target: self),
                .separator(),
                zoom("Zoom In", 1, "+"),
                // ⌘= as well as ⌘+: they're the same key on most keyboards.
                hidden(zoom("Zoom In", 1, "=")),
                zoom("Zoom Out", -1, "-"),
                zoom("Actual Size", 0, "0"),
                .separator(),
                item("Choose New Tab Picture…", #selector(choosePicture), target: self),
                item("Use Nerda's Pictures", #selector(useOwnPictures), target: self),
            ]),
            historyMenu,
            windowMenu,
        ]
        historyMenu.submenu?.delegate = self
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.servicesMenu = servicesMenu.submenu

        // A focused page takes ⌃Tab as a key of its own, so it would never
        // reach the menu: it is caught on its way in instead. So are the keys
        // that are the browser's whatever the page does with them, as in
        // Chrome: a page that took ⌘W or ⌘T for itself would keep you in it.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] {
                MainActor.assumeIsolated { if !browser.locked { browser.selectTab(after: modifiers.contains(.shift) ? -1 : 1) } }
                return nil
            }
            // ⌘1 to ⌘9 by the key, not the character it types: on AZERTY that
            // is & é " ' and the rest, which no menu item has.
            if modifiers == .command, let index = Self.digitKeys.firstIndex(of: event.keyCode),
               event.window?.attachedSheet == nil, NSApp.modalWindow == nil {
                MainActor.assumeIsolated { if !browser.locked { browser.selectTab(number: index + 1) } }
                return nil
            }
            return MainActor.assumeIsolated { Self.browserKey(event) } ? nil : event
        }
    }

    /// The keys 1 to 9 of the row above the letters, by their place.
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// ⌘T and the rest by their place, as on a US keyboard, for a layout that
    /// types no Latin letters (Russian, Uzbek Cyrillic): there ⌘T types "е".
    private static let latinKeys: [UInt16: String] = [17: "t", 13: "w", 37: "l", 12: "q", 43: ",", 0: "a", 45: "n"]

    /// ⌘T, ⌘W, ⌘L, ⌘Q and ⌘, and ⌘⇧W, ⌘⇧A and ⌘⇧N, straight to the menu while
    /// a page has the keyboard (and no sheet or dialog is up).
    private static func browserKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let window = event.window, window.firstResponder is WKWebView, window.attachedSheet == nil,
              NSApp.modalWindow == nil, let typed = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let key = typed.allSatisfy(\.isASCII) ? typed : latinKeys[event.keyCode] ?? typed
        let reserved = modifiers == .command && ["t", "w", "l", "q", ","].contains(key)
            || modifiers == [.command, .shift] && ["w", "a", "n"].contains(key)
        return reserved && NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }

    /// With no window in front (the last tab closed its window), ⌘T brings
    /// the regular one back on a new tab, as Chrome opens a window for it.
    @objc private func newTab() {
        if let browser = (NSApp.mainWindow as? BrowserWindow)?.browser { return browser.newTab() }
        let browser = Windows.showRegular()
        if browser.selected?.isBlank != true { browser.newTab() }
    }

    /// The browser of the window in front; with none, the regular window,
    /// brought back, for what opens a tab or a field in it.
    private var shown: Browser { (NSApp.mainWindow as? BrowserWindow)?.browser ?? Windows.showRegular() }

    @objc private func newIncognitoWindow() { Windows.openIncognito() }
    @objc private func openSettings() { shown.openSettings() }
    @objc private func openHistory() { shown.openHistory() }
    @objc private func searchTabs() { shown.showCommandBar() }
    @objc private func openLocation() { shown.editAddress() }
    @objc private func closeTab() { browser.closeSelectedTab() }
    @objc private func toggleSidebar() { browser.toggleSidebar() }
    @objc private func reload() { browser.selected?.reload() }
    @objc private func hardReload() { browser.selected?.reload(fromOrigin: true) }
    @objc private func goBack() { browser.selected?.webView.goBack() }
    @objc private func goForward() { browser.selected?.webView.goForward() }
    @objc private func zoom(_ sender: NSMenuItem) { browser.selected?.zoom(sender.tag) }
    @objc private func selectTab(_ sender: NSMenuItem) { browser.selectTab(number: sender.tag) }
    @objc private func nextTab() { browser.selectTab(after: 1) }
    @objc private func previousTab() { browser.selectTab(after: -1) }
    @objc private func importPasswords() { browser.importPasswords() }
    @objc private func useOwnPictures() { Backdrop.shared.wallpaper = .daily }
    @objc private func choosePicture() { Backdrop.shared.askForPicture() }

    private func zoom(_ title: String, _ step: Int, _ key: String) -> NSMenuItem {
        let item = item(title, #selector(zoom(_:)), key, target: self)
        item.tag = step
        return item
    }

    @objc private func checkForUpdates() { Updater.shared.check(asked: true) }

    @objc private func openVisit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let browser = shown
        if browser.commandBarOpen { browser.hideCommandBar() }
        browser.go(to: url)
    }

    @objc private func clearHistory() { shown.clearHistory() }

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
        // A locked incognito window's tabs are out of reach; what goes to the
        // regular window, or unlocks first (a new incognito window), is not.
        if browser.locked {
            return [#selector(openSettings), #selector(openHistory), #selector(newIncognitoWindow),
                    #selector(checkForUpdates), #selector(importPasswords),
                    #selector(choosePicture), #selector(useOwnPictures)].contains(item.action)
        }
        switch item.action {
        case #selector(toggleSidebar):
            item.title = browser.sidebarOpen ? "Collapse Tabs" : "Show Tabs"
            // Tabs across the top have no sidebar to collapse.
            return TabStyle.current == .vertical
        case #selector(closeTab):
            return browser.commandBarOpen || browser.selectedID != nil
        case #selector(reload), #selector(hardReload), #selector(zoom(_:)):
            // Actual Size only once there is a zoom to undo.
            guard let tab = browser.selected, tab.hasPage else { return false }
            return item.action != #selector(zoom(_:)) || item.tag != 0 || tab.webView.pageZoom != PageZoom.current
        case #selector(showFind):
            return browser.selected?.hasPage == true
        case #selector(findNext), #selector(findPrevious):
            return browser.selected?.hasPage == true && !browser.findQuery.isEmpty
        case #selector(nextTab), #selector(previousTab):
            return browser.tabs.count > 1
        case #selector(goBack):
            return browser.selected?.canGoBack == true
        case #selector(goForward):
            return browser.selected?.canGoForward == true
        case #selector(checkForUpdates):
            return Updater.shared.canCheck
        case #selector(useOwnPictures):
            return Backdrop.shared.wallpaper != .daily
        case #selector(clearHistory):
            return !History.shared.visits.isEmpty
        default:
            return true
        }
    }
}

extension AppMenu: NSMenuDelegate {
    /// Under Back, Forward and Show All History, the pages visited last, as Safari lists them;
    /// each opens in a tab of its own.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > 3 { menu.removeItem(at: 3) }
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
        if menu.items.count > 4 { menu.addItem(.separator()) }
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

    /// An incognito window's closing lets go of it, and with the last one,
    /// of all it held (see `Windows`).
    func windowWillClose(_ notification: Notification) {
        browser.closeAll()
        if browser.isPrivate { Windows.closed(self) }
    }

    /// The window comes back with the tabs it closed with.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            browser.restore(from: Session.file)
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Links from other apps always open in the regular window.
    func application(_ application: NSApplication, open urls: [URL]) {
        let links = urls.filter {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false
        }
        guard !links.isEmpty else { return }
        if browser.tabs.isEmpty { browser.restore(from: Session.file) }
        if browser.commandBarOpen { browser.hideCommandBar() }
        browser.endAddressEdit()
        for url in links { browser.go(to: url) }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        application.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // With no tabs there is nothing to lose.
        guard QuitConfirmation.isWanted, !browser.tabs.isEmpty, !QuitConfirmation.systemIsQuitting,
              !Updater.shared.relaunching
        else {
            return .terminateNow
        }
        switch QuitConfirmation.ask() {
        case .cancel:
            return .terminateCancel
        case .alwaysQuit:
            QuitConfirmation.isWanted = false
            return .terminateNow
        case .quit:
            return .terminateNow
        }
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
