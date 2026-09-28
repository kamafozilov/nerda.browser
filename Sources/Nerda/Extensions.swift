import AppKit
import IOKit.pwr_mgt
import SwiftUI
import WebKit

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the one Safari runs its extensions
// on, reading the same manifest.json a Chrome extension ships. What is here
// is the browser's half of the contract: which tabs exist and which one is
// on screen, what a new tab or a popup means here, who is asked for a
// permission and how. Beside it: installing from the Chrome Web Store
// (Crx.swift, WebStore.swift), the Chrome APIs WebKit lacks, filled in by
// Nerda (ExtensionShims.swift, ExtensionNative.swift, ExtensionSocket.swift),
// and an extension's popup (ExtensionPopup.swift). Extensions see the
// regular window's tabs; incognito windows keep them out, as Chrome does
// until told otherwise.
//
// Tab is a Swift class and WebKit's protocols are Objective-C ones, so each
// tab is shown to WebKit by a small adapter kept here. A tab can have no page
// at all (asleep, or a new tab) and is reported with none: `page` is read,
// never `webView`, which would make one.
//
// This and the files named above follow Search's (https://github.com/driceroland/Search),
// much of them as they are there:
//
//   Copyright (c) 2026 Office Commun
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

/// One installed extension, as Settings › Extensions lists it.
nonisolated struct InstalledExtension: Codable, Identifiable, Equatable, Sendable {
    /// The Chrome Web Store id, or "local-…" for one loaded from a folder.
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// What it was installed with, so an update that asks for more is asked
    /// about rather than slipped through (see `grants`).
    var permissions: [String]
    /// Its button kept in the address bar, beside the extensions button.
    var pinned: Bool? = nil
    /// For one loaded from a folder: where that folder is, so Reload brings
    /// its author's latest edits in.
    var source: String? = nil
}

@Observable
final class Extensions: NSObject {
    static let shared = Extensions()

    @ObservationIgnored let controller: WKWebExtensionController
    private(set) var installed: [InstalledExtension] = [] {
        didSet { tellStores() }
    }
    /// The loaded ones, by id.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes: icon, badge, enabled.
    private(set) var actionsChanged = 0
    /// Bumped when an extension changes a browser setting (chrome.privacy).
    var settingsChanged = 0
    /// The extension on its way in from the store.
    private(set) var busy: String? {
        didSet { tellStores() }
    }
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    private(set) var errors: [String: [String]] = [:]
    /// The list behind the extensions button in the address bar.
    var menuOpen = false

    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored private var adapters: [Tab.ID: ExtensionTab] = [:]
    @ObservationIgnored private var order: [Tab.ID] = []
    @ObservationIgnored private(set) lazy var window = ExtensionWindow(owner: self)
    /// Where each extension's button is on screen, for its popup to hang from.
    @ObservationIgnored var anchors: [String: WeakView] = [:]
    /// Where a popup hangs when its extension isn't pinned: the extensions button.
    static let menuAnchor = "__menu"

    static let folder = Edition.folder.appending(path: "Extensions", directoryHint: .isDirectory)
    private static var list: URL { folder.appending(path: "installed.json") }
    static func folder(for id: String) -> URL { folder.appending(path: id, directoryHint: .isDirectory) }
    /// Where a new copy is unpacked before it takes an extension's place:
    /// a name of its own each time, so one left by a crash is never in the way.
    private static func staging(for id: String) -> URL {
        folder.appending(path: ".staging-\(id)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Puts a new copy of an extension where the old one is in one step:
    /// the two folders swap places, so if anything fails the copy that works
    /// stays where it was. The old one is left at `staged`, to be removed.
    nonisolated static func replace(_ staged: URL, at target: URL) throws {
        func rename(_ flags: Int32) -> Int32? {
            staged.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return EINVAL }
                    return renamex_np(from, to, UInt32(flags)) == 0 ? nil : errno
                }
            }
        }
        guard var failed = rename(RENAME_EXCL) else { return }
        if failed == EEXIST {
            guard let swapFailed = rename(RENAME_SWAP) else { return }
            failed = swapFailed
        }
        throw POSIXError(POSIXErrorCode(rawValue: failed) ?? .EIO)
    }

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome, with the same ids: servers let their own
    /// extension in by that origin, and sites look for one at it.
    nonisolated static let scheme = "chrome-extension"

    /// The extension an address is a page of, or nil for the web.
    nonisolated static func host(of url: URL?) -> String? {
        url?.scheme == scheme ? url?.host() : nil
    }

    // MARK: - what an extension may never do

    /// The schemes extension pages are served from: Nerda's, and WebKit's own.
    nonisolated static let pageSchemes: Set<String> = [scheme, "webkit-extension"]

    /// Extension pages, as a pattern names them: another extension's
    /// (chrome-extension://<its id>/*) or every one's. No extension is ever
    /// given them, not from its manifest, not asked for later, as Chrome
    /// doesn't; its own pages are its own without asking.
    nonisolated static func reachesExtensions(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        pageSchemes.contains(pattern.scheme?.lowercased() ?? "")
    }

    /// Other extensions' pages are never among "all sites" either: with
    /// chrome-extension registered as a scheme, WebKit counts them in
    /// <all_urls>, which Chrome doesn't, so they are refused outright. A
    /// refusal for all hosts doesn't outweigh a grant naming one, WebKit
    /// looks at those first, which is why none is ever made (see
    /// `reachesExtensions`). Set again after anything is granted.
    static func fence(_ context: WKWebExtensionContext) {
        for scheme in pageSchemes {
            if let pages = try? WKWebExtension.MatchPattern(string: "\(scheme)://*/*") {
                context.setPermissionStatus(.deniedExplicitly, for: pages)
            }
        }
    }

    /// Whether this address is a page of an extension other than the one
    /// asking, which it never gets to see into.
    nonisolated static func othersPage(_ url: URL?, of id: String) -> Bool {
        guard let url, pageSchemes.contains(url.scheme?.lowercased() ?? "") else { return false }
        return url.host()?.lowercased() != id.lowercased()
    }

    static func othersPage(_ url: URL?, for context: WKWebExtensionContext) -> Bool {
        othersPage(url, of: context.uniqueIdentifier)
    }

    /// Where an extension may send a tab. Not to javascript:, which would run
    /// its code in whatever page the tab shows, a site it may have no access
    /// to at all, nor to a file on this Mac. Chrome refuses both.
    nonisolated static func mayOpen(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme != "javascript", scheme != "file" else {
            throw NSError(domain: "Nerda", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot navigate to a \(scheme): URL."])
        }
    }

    /// When you last pressed each extension's button.
    static var clicked: [String: Date] = [:]
    /// When you last clicked or typed in one of each extension's own pages:
    /// its popup, or a page of its in a tab. Real events only: a page's
    /// script can dispatch one, but it never reaches here.
    static var touched: [String: Date] = [:]
    private static var touching: Any?

    static func watchTouches() {
        guard touching == nil else { return }
        touching = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            var view: NSView? = event.type == .keyDown
                ? event.window?.firstResponder as? NSView
                : event.window?.contentView?.superview?.hitTest(event.locationInWindow)
            while let found = view, !(found is WKWebView) { view = found.superview }
            if let id = host(of: (view as? WKWebView)?.url) { touched[id] = Date() }
            return event
        }
    }

    /// You just did something in this extension, its button or a click or a
    /// key in one of its pages, as Chrome's "user gesture" means: within the
    /// last few seconds.
    static func justUsed(_ id: String) -> Bool {
        let latest = [clicked[id], touched[id]].compactMap { $0 }.max()
        return latest.map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    /// The configuration an extension's page has to be made with, as only a
    /// view made from its extension's is served its pages; nil for the web.
    static func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard host(of: url) != nil else { return nil }
        return shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    func noteError(_ text: String, for id: String) {
        NSLog("Nerda: extension %@: %@", id, text)
        errors[id] = Array(((errors[id] ?? []) + [text]).suffix(40))
    }

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = .default()
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        views.websiteDataStore = .default()
        // The same user agent as the tabs, to the letter. WebKit gives
        // workers the user agent of the last page that loaded and, when it
        // differs, stops the running workers to apply it, and extension
        // workers it then never starts again. Extensions are told they run in
        // Chrome by the shim instead.
        views.applicationNameForUserAgent = Tab.applicationName
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        installed = (try? JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: Self.list))) ?? []
    }

    // MARK: - starting

    /// Whether `start` has run. Until then the tabs have no one to tell of
    /// them, and telling would make `shared` before the window is up.
    static private(set) var started = false

    /// The regular window's browser, once its window is up: loading an
    /// extension takes the main thread for tens of milliseconds, and the
    /// first frame shouldn't wait for it.
    func start(for browser: Browser) {
        Self.started = true
        self.browser = browser
        controller.didOpenWindow(window)
        follow(browser)
        Task {
            // One after another, a moment apart: started all at once, WebKit
            // fails some of their workers and never tries them again.
            for item in installed where item.enabled {
                await load(item)
                if contexts[item.id]?.webExtension.hasBackgroundContent == true {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            checkForUpdates()
        }
    }

    // MARK: - the tabs, as WebKit sees them

    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    /// In the order they are on screen.
    var visibleTabs: [Tab] { browser?.inTurn ?? [] }

    /// Where each tab is in `visibleTabs`. WebKit asks it of every tab at
    /// each tabs.query and each tab's update, and working the order out
    /// walks every bookmark; so it is worked out once, and kept to the end
    /// of the turn or until the tabs change.
    @ObservationIgnored private var places: [Tab.ID: Int]?

    func place(of tab: Tab) -> Int? {
        if places == nil {
            places = Dictionary(visibleTabs.enumerated().map { ($1.id, $0) }) { first, _ in first }
            DispatchQueue.main.async { self.places = nil }
        }
        return places?[tab.id]
    }

    var activeAdapter: ExtensionTab? { browser?.selected.map(adapter(for:)) }

    /// The tabs changed: opened, closed or moved. Browser tells.
    func follow(_ browser: Browser) {
        guard browser === self.browser else { return }
        ExtensionAuth.tabsChanged(browser.tabs)
        places = nil
        let now = visibleTabs
        let ids = now.map(\.id)
        let current = Set(ids), before = Set(order)
        for id in order where !current.contains(id) {
            if let adapter = adapters[id] { controller.didCloseTab(adapter, windowIsClosing: false) }
            adapters[id] = nil
        }
        for tab in now where !before.contains(tab.id) {
            controller.didOpenTab(adapter(for: tab))
        }
        // Moves: anything whose place changed among the ones that stayed.
        let stayed = order.filter(current.contains)
        let after = ids.filter(before.contains)
        for (index, id) in stayed.enumerated() where after[index] != id {
            if let adapter = adapters[id] { controller.didMoveTab(adapter, from: index, in: window) }
        }
        order = ids
    }

    /// Another tab came on screen. Browser tells.
    func activated(_ browser: Browser, from old: Tab.ID?) {
        guard browser === self.browser, let tab = browser.selected else { return }
        let previous = old.flatMap { id in browser.tabs.first { $0.id == id } }.map(adapter(for:))
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
        actionsChanged += 1
    }

    /// A tab's title, address or loading changed. Tab tells. WebKit sets
    /// them one after another as a page starts and ends, and each told on
    /// its own is an onUpdated of its own, with the whole tab described
    /// for every extension; so what changes in one turn is told once, as
    /// Chrome tells a new address and "loading" together.
    func changed(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        guard adapters[tab.id] != nil else { return }
        if untold.isEmpty { DispatchQueue.main.async { self.tellChanges() } }
        untold[tab.id, default: []].formUnion(properties)
    }

    @ObservationIgnored private var untold: [Tab.ID: WKWebExtension.TabChangedProperties] = [:]

    private func tellChanges() {
        let changes = untold
        untold = [:]
        places = nil
        for (id, properties) in changes {
            if let adapter = adapters[id] { controller.didChangeTabProperties(properties, for: adapter) }
        }
    }

    // MARK: - loading

    @discardableResult
    private func load(_ item: InstalledExtension) async -> Bool {
        // The shim this build carries, in place of whatever the build that
        // installed it carried: away from the main thread, as the first
        // launch after an update reads and rewrites every script and page.
        let folder = Self.folder(for: item.id)
        try? await Task.detached(priority: .userInitiated) { try ExtensionShims.prepare(folder) }.value
        do {
            let found = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and all an extension keeps in its own pages
            // (localStorage, IndexedDB) is filed under its origin.
            if let stable = URL(string: "\(Self.scheme)://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: all it asked for then is granted
            // each time it loads. Optional ones are asked for when it asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            // Never one for extension pages, another's or all of them (see
            // `fence`).
            for pattern in found.allRequestedMatchPatterns where !Self.reachesExtensions(pattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            Self.fence(context)
            // WebKit's nativeMessaging, granted above to all, is the shim's
            // line to Nerda; an app on this Mac answers only an extension
            // whose own manifest asks for it, required or optional, as in
            // Chrome. What Nerda added to the manifest doesn't count.
            let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: ".nerda-added")))) as? [String] ?? [])
            if found.optionalPermissions.contains(.nativeMessaging)
                || found.requestedPermissions.contains(.nativeMessaging) && !added.contains("nativeMessaging") {
                talksToApps.insert(item.id)
            } else {
                talksToApps.remove(item.id)
            }
            Self.watchTouches()
            try controller.load(context)
            watch(context)
            if contexts[item.id] == nil, loadsThisRun.contains(item.id) { loadedBefore.insert(item.id) }
            loadsThisRun.insert(item.id)
            contexts[item.id] = context
            actionsChanged += 1
            return true
        } catch {
            NSLog("Nerda: couldn't load extension %@: %@", item.id, error.localizedDescription)
            noteError("couldn't start: \(error.localizedDescription)", for: item.id)
            return false
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts[id] else { return }
        if ExtensionPopup.shared.extensionID == id { ExtensionPopup.shared.close() }
        try? controller.unload(context)
        // What it kept going outside WebKit goes with it: its offscreen
        // page, and a Mac kept awake on its behalf.
        ExtensionShims.offscreen[id] = nil
        if let held = ExtensionShims.awake.removeValue(forKey: id) { IOPMAssertionRelease(held) }
        // Its ports read as gone only once WebKit has had a turn.
        DispatchQueue.main.async { ExtensionNative.stopOrphans() }
        contexts[id] = nil
        actionsChanged += 1
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: Self.list, options: .atomic)
    }

    /// Loaded at least once since Nerda started, and loaded again: an
    /// "install" then is a restart (see the shim).
    @ObservationIgnored private var loadsThisRun: Set<String> = []
    @ObservationIgnored private(set) var loadedBefore: Set<String> = []

    // MARK: - installing

    /// A Chrome Web Store link or an extension's id: from the store page's
    /// Add to Nerda, the extensions list, or Settings › Extensions.
    func install(from text: String) {
        guard let id = Crx.id(in: text) else { return fail(Crx.Refused.notAnID.localizedDescription) }
        if installed.contains(where: { $0.id == id }) {
            menuOpen = true
            return
        }
        guard busy == nil else { return }
        busy = id
        Task {
            defer { busy = nil }
            do {
                let crx = try await Crx.fetch(id)
                let staged = Self.staging(for: id)
                defer { try? FileManager.default.removeItem(at: staged) }
                // Checked where it is unpacked, off the main thread: the
                // check copies and hashes the whole package.
                try await Task.detached(priority: .userInitiated) {
                    let zip = try Crx.verifiedZip(crx, id: id)
                    try Crx.unpack(zip, into: staged)
                    try ExtensionShims.prepare(staged, fresh: true)
                }.value
                try await admit(staged, as: id, fromStore: true)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// An unpacked extension from disk: a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        guard let window = browser?.window else { return }
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let source = panel.url else { return }
            MainActor.assumeIsolated { self.installFolder(at: source) }
        }
    }

    func installFolder(at source: URL) {
        guard FileManager.default.fileExists(atPath: source.appending(path: "manifest.json").path) else {
            return fail("That folder has no manifest.json.")
        }
        let id = "local-" + UUID().uuidString.prefix(8).lowercased()
        let staged = Self.staging(for: id)
        do {
            try Self.copy(source, to: staged)
        } catch {
            return fail("The extension couldn't be copied.")
        }
        Task {
            defer { try? FileManager.default.removeItem(at: staged) }
            do { try await admit(staged, as: id, fromStore: false, source: source) } catch { fail(error.localizedDescription) }
        }
    }

    /// A folder's extension copied in afresh and prepared.
    private static func copy(_ source: URL, to staged: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.copyItem(at: source, to: staged)
        do {
            try ExtensionShims.prepare(staged, fresh: true)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
    }

    /// Takes the extension up again, as Chrome's reload does in developer
    /// mode. One loaded from a folder is copied in afresh from it first, so
    /// what its author just saved is what runs.
    func reload(_ id: String) {
        guard let item = installed.first(where: { $0.id == id }), reloading.insert(id).inserted else { return }
        let target = Self.folder(for: id)
        var staged: URL?
        if let path = item.source {
            let copy = Self.staging(for: id)
            do {
                try Self.copy(URL(fileURLWithPath: path, isDirectory: true), to: copy)
            } catch {
                reloading.remove(id)
                return fail("\(item.name) couldn't be copied again from its folder.")
            }
            staged = copy
        }
        Task {
            defer {
                if let staged { try? FileManager.default.removeItem(at: staged) }
                reloading.remove(id)
            }
            let found = try? await WKWebExtension(resourceBaseURL: staged ?? target)
            if found == nil, staged != nil {
                return fail("\(item.name) wasn't reloaded: its manifest couldn't be read.")
            }
            if let found {
                let wants = Set(Self.grants(found, in: staged ?? target))
                if !wants.isSubset(of: Set(item.permissions)) {
                    let name = [found.displayName ?? item.name, found.version].compactMap { $0 }.joined(separator: " ")
                    guard await ask(install: name, wants: Self.describe(found, in: staged ?? target), icon: found.icon(for: CGSize(width: 64, height: 64))) else { return }
                }
            }
            if let staged {
                do {
                    try Self.replace(staged, at: target)
                } catch {
                    return fail("\(item.name) couldn't be copied again from its folder.")
                }
            }
            unload(id)
            errors[id] = nil
            if let found, let index = installed.firstIndex(where: { $0.id == id }) {
                installed[index].name = found.displayName ?? installed[index].name
                installed[index].version = found.version ?? installed[index].version
                installed[index].permissions = Self.grants(found, in: target)
                save()
            }
            guard let item = installed.first(where: { $0.id == id }), item.enabled else { return }
            if await !load(item) { fail("\(item.name) couldn't start. Settings › Extensions says why.") }
        }
    }

    @ObservationIgnored private var reloading: Set<String> = []
    /// When each extension was last taken up afresh by `revive`.
    @ObservationIgnored private var revived: [String: Date] = [:]
    /// Recent failed native messages, per extension and host.
    @ObservationIgnored private var failures: [String: [Date]] = [:]
    /// The extensions that asked to talk to apps on this Mac (see `load`).
    @ObservationIgnored private var talksToApps: Set<String> = []

    /// An extension whose worker won't start again: unloaded and loaded, as
    /// a relaunch would, at most once a minute, so one that can never start
    /// doesn't go round in circles.
    func revive(_ id: String, because reason: String) {
        guard let item = installed.first(where: { $0.id == id }), item.enabled,
              Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return }
        revived[id] = Date()
        noteError("restarted the extension: \(reason)", for: id)
        // Its popup goes with it, and is opened again once it is back.
        let popup = ExtensionPopup.shared.extensionID == id ? ExtensionPopup.shared.view?.url : nil
        let anchor = anchor(for: id)
        unload(id)
        Task {
            guard await load(item), let popup, let context = contexts[id] else { return }
            ExtensionPopup.shared.show(popup, for: context, from: anchor)
        }
    }

    /// WebKit records a worker that failed to start as an error on its
    /// context, and then doesn't try again: the extension would be dead
    /// until someone noticed. It is taken up afresh as soon as that shows.
    @ObservationIgnored private var errorWatchers: [String: NSObjectProtocol] = [:]
    private func watch(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        errorWatchers[id] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main
        ) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let error = error as NSError
                    return error.domain == WKWebExtensionContext.errorDomain
                        && error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.contexts[id] === context else { return }
                    self.revive(id, because: "its worker failed to start")
                }
            }
        }
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned = on
        save()
    }

    /// Reads what was unpacked, asks, and on yes moves it into place and
    /// loads it. The caller removes what is left at `staged`.
    private func admit(_ staged: URL, as id: String, fromStore: Bool, source: URL? = nil) async throws {
        let found = try await WKWebExtension(resourceBaseURL: staged)
        let name = found.displayName ?? id
        guard await ask(install: name, wants: Self.describe(found, in: staged), icon: found.icon(for: CGSize(width: 64, height: 64))) else {
            return
        }
        let target = Self.folder(for: id)
        try Self.replace(staged, at: target)
        let item = InstalledExtension(
            id: id, name: name, version: found.version ?? "?", enabled: true, fromStore: fromStore,
            permissions: Self.grants(found, in: target), source: source?.path
        )
        installed.removeAll { $0.id == id }
        installed.append(item)
        save()
        if await load(item) {
            // Where it is now, as Chrome shows it once added.
            menuOpen = true
        } else {
            fail("\(name) was added, but it couldn't start. Settings › Extensions says why.")
        }
    }

    func remove(_ id: String) {
        unload(id)
        errors[id] = nil
        Self.setSettings([:], for: id)
        UserDefaults.standard.removeObject(forKey: "extensions.granted.\(id)")
        UserDefaults.standard.removeObject(forKey: Self.newTabKey(id))
        loadsThisRun.remove(id)
        loadedBefore.remove(id)
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: Self.folder(for: id))
    }

    /// Asks first, as removing takes its settings and data with it.
    func confirmRemove(_ id: String) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        Task {
            if await ask("Remove “\(item.name)”?", detail: "Its settings and data go with it.",
                         icon: contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Remove", no: "Cancel") {
                remove(id)
            }
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save()
        if on {
            let item = installed[index]
            Task { await load(item) }
        } else {
            unload(id)
        }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser?.open(url)
    }

    // MARK: - new tab pages

    private static func newTabKey(_ id: String) -> String { "extensions.newtab.\(id)" }

    /// The page an extension asks to show in new tabs, from the one added
    /// last, once you said yes to it. Nil while none asks, or you said no.
    var newTabPage: URL? {
        guard let (id, url) = newTabCandidate else { return nil }
        return UserDefaults.standard.object(forKey: Self.newTabKey(id)) as? Bool == true ? url : nil
    }

    private var newTabCandidate: (String, URL)? {
        for item in installed.reversed() where item.enabled {
            if let url = contexts[item.id]?.overrideNewTabPageURL { return (item.id, url) }
        }
        return nil
    }

    /// Chrome asks the first time an extension's page takes the place of the
    /// new tab: one that did it quietly could be anything. So does Nerda, and
    /// on yes shows it in the new tab just opened.
    func offerNewTabPage(into tab: Tab) {
        guard let (id, url) = newTabCandidate, UserDefaults.standard.object(forKey: Self.newTabKey(id)) == nil,
              let name = installed.first(where: { $0.id == id })?.name else { return }
        Task {
            let yes = await ask("Show “\(name)” in new tabs?",
                                detail: "It asked to replace the new tab page. You can change this in Settings › Extensions.",
                                icon: contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Keep It", no: "Don't Allow")
            UserDefaults.standard.set(yes, forKey: Self.newTabKey(id))
            if yes, tab.isBlank { tab.go(to: url) }
        }
    }

    func showsNewTab(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: Self.newTabKey(id)) as? Bool == true
    }

    func setShowsNewTab(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.newTabKey(id))
        settingsChanged += 1
    }

    // MARK: - browser settings extensions set

    /// What an extension set through chrome.privacy and chrome.proxy.
    static func settings(for id: String) -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: "extensions.settings.\(id)") ?? [:]
    }

    static func setSettings(_ values: [String: Any], for id: String) {
        if values.isEmpty { UserDefaults.standard.removeObject(forKey: "extensions.settings.\(id)") }
        else { UserDefaults.standard.set(values, forKey: "extensions.settings.\(id)") }
    }

    /// The extension, on, that asked the browser not to offer to save
    /// passwords: a password manager doing the saving itself.
    var passwordSavingTakenBy: String? {
        _ = settingsChanged
        return installed.first {
            $0.enabled && contexts[$0.id] != nil && Self.settings(for: $0.id)["privacy.services.passwordSavingEnabled"] as? Bool == false
        }?.name
    }

    // MARK: - updates

    /// Once a day, the store is asked whether anything installed from it has
    /// a newer version; if so it is fetched, checked and swapped in. One that
    /// asks for more than it was installed with is asked about first.
    func checkForUpdates() {
        let key = "extensions.checked"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 60 * 60 else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        for item in installed where item.fromStore {
            Task { await update(item) }
        }
    }

    private func update(_ item: InstalledExtension) async {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(item.id)&v=\(item.version)&uc"),
        ]
        guard let url = parts.url, let version = await Self.newerVersion(at: url, than: item.version) else { return }
        do {
            let crx = try await Crx.fetch(item.id)
            let staged = Self.staging(for: item.id)
            defer { try? FileManager.default.removeItem(at: staged) }
            try await Task.detached(priority: .utility) {
                let zip = try Crx.verifiedZip(crx, id: item.id)
                try Crx.unpack(zip, into: staged)
                try ExtensionShims.prepare(staged, fresh: true)
            }.value
            let found = try await WKWebExtension(resourceBaseURL: staged)
            // All it could do, sites included, against what it was allowed
            // when it was added or last asked about.
            let wants = Set(Self.grants(found, in: staged))
            if !wants.isSubset(of: Set(item.permissions)) {
                guard await ask(install: "An update to \(item.name)", wants: Self.describe(found, in: staged),
                                icon: found.icon(for: CGSize(width: 64, height: 64))) else { return }
            }
            try Self.replace(staged, at: Self.folder(for: item.id))
            unload(item.id)
            if let index = installed.firstIndex(where: { $0.id == item.id }) {
                installed[index].version = found.version ?? version
                installed[index].permissions = wants.sorted()
                save()
                if installed[index].enabled { await load(installed[index]) }
            }
        } catch {
            NSLog("Nerda: update of extension %@ failed: %@", item.id, error.localizedDescription)
        }
    }

    /// The store's answer to an update check: the version in its
    /// <updatecheck> when that says status="ok" and differs from ours. Read
    /// across the whole reply, the first version="" is the XML declaration's.
    nonisolated static func newerVersion(in xml: String, than current: String) -> String? {
        guard let check = xml.range(of: #"<updatecheck\b[^>]*>"#, options: .regularExpression).map({ String(xml[$0]) }),
              check.contains("status=\"ok\""),
              let version = check.range(of: #"\bversion="([^"]+)""#, options: .regularExpression)
                .map({ String(check[$0].dropFirst(9).dropLast()) }),
              version != current
        else { return nil }
        return version
    }

    private static func newerVersion(at url: URL, than current: String) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return newerVersion(in: xml, than: current)
    }

    // MARK: - popups

    /// The copy an extension's popup page is loaded from, beside it.
    ///
    /// WebKit takes any page at the path of an extension's popup for its own
    /// popup, and a popup that isn't in WebKit's own view (Nerda's is its
    /// own, see ExtensionPopup) is sent no events: no storage.onChanged, no
    /// tabs.onUpdated. Bitwarden's popup never heard its server had changed.
    /// So the page is loaded from a copy under another name, in the same
    /// folder: the same file, the same files round it, and none of WebKit's
    /// rules for popups. Anything else is loaded as it is.
    static let popupCopy = ".nerda-popup"

    static func unpopped(_ url: URL) -> URL {
        guard let id = host(of: url), let context = shared.contexts[id],
              !url.lastPathComponent.contains(popupCopy)
        else { return url }
        let named = [popupURL(for: context)]
            + (ExtensionShims.popups[id]?.values.map { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL } ?? [])
        guard named.contains(where: { $0?.path == url.path }) else { return url }
        guard let original = ExtensionShims.inside(url.path, of: folder(for: id)),
              let data = try? Data(contentsOf: original)
        else { return url }
        let ext = original.pathExtension
        let name = original.deletingPathExtension().lastPathComponent + popupCopy + (ext.isEmpty ? "" : "." + ext)
        let copy = original.deletingLastPathComponent().appending(path: name)
        if (try? Data(contentsOf: copy)) != data {
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return url }
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = (url.path as NSString).deletingLastPathComponent.appending("/" + name).replacingOccurrences(of: "//", with: "/")
        return parts.url ?? url
    }

    /// Whether a website at `site` may open this extension page, as Chrome
    /// decides: the page is among its manifest's web_accessible_resources,
    /// for every site (Manifest V2) or for sites its `matches` name.
    func opens(_ url: URL, from site: URL?) -> Bool {
        guard let id = Self.host(of: url), let context = contexts[id] else { return false }
        return Self.webAccessible(url, from: site, in: context.webExtension.manifest)
    }

    /// Stricter than Chrome where it can't be told apart safely: only a
    /// secure site, only a page named plainly (no "..", no encoded slash),
    /// only `*` in the manifest's names, and no page it hides behind a
    /// changing address (use_dynamic_url). Anything else stays closed.
    static func webAccessible(_ url: URL, from site: URL?, in manifest: [String: Any]) -> Bool {
        guard let site, site.scheme?.lowercased() == "https", let host = site.host(), !host.isEmpty,
              site.user == nil, site.password == nil,
              url.user == nil, url.password == nil, url.port == nil,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              !encoded.lowercased().contains("%2f"), !encoded.lowercased().contains("%5c"),
              let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("/"),
              let path = plain(decoded.dropFirst())
        else { return false }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.port = site.port
        parts.path = "/"
        guard let origin = parts.url else { return false }
        let named = { (resources: [String]) in
            resources.contains { resource in
                guard let resource = plain(resource.hasPrefix("/") ? resource.dropFirst() : Substring(resource)) else { return false }
                let pattern = "\\A" + resource.components(separatedBy: "*").map(NSRegularExpression.escapedPattern).joined(separator: ".*") + "\\z"
                return path.range(of: pattern, options: .regularExpression) != nil
            }
        }
        switch manifest["manifest_version"] as? Int {
        case 2:
            return named(manifest["web_accessible_resources"] as? [String] ?? [])
        case 3:
            return (manifest["web_accessible_resources"] as? [[String: Any]] ?? []).contains { rule in
                if let dynamic = rule["use_dynamic_url"], dynamic as? Bool != false { return false }
                return named(rule["resources"] as? [String] ?? [])
                    && (rule["matches"] as? [String] ?? []).contains { (try? WKWebExtension.MatchPattern(string: $0))?.matches(origin) == true }
            }
        default:
            return false
        }
    }

    /// A path as it reads, or nil for one that reads two ways: a backslash,
    /// a "." or ".." or empty step, a control character.
    private static func plain(_ path: Substring) -> String? {
        guard !path.isEmpty, !path.contains("\\"), !path.contains("%"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        return String(path)
    }

    /// The page the manifest names for the button, when WebKit hasn't said.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let path = action?["default_popup"] as? String, !path.isEmpty else { return nil }
        // Relative to the extension, and keeping a query it may carry.
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// The page the button's popup is now: one the extension set for this
    /// tab or for all of them, else its manifest's.
    private func currentPopupURL(for context: WKWebExtensionContext) -> URL? {
        let set = ExtensionShims.popups[context.uniqueIdentifier] ?? [:]
        let path = browser?.selected.flatMap { set[$0.id.uuidString] } ?? set["*"]
        guard let path else { return Self.popupURL(for: context) }
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// What a popup hangs from: its own button if pinned and on screen, else
    /// the extensions button.
    private func anchor(for id: String) -> NSView? {
        if let own = anchors[id]?.view, own.window != nil { return own }
        return anchors[Self.menuAnchor]?.view
    }

    // MARK: - asking

    /// What an extension was allowed, as written down and compared on every
    /// update: WebKit's permissions, the sites it reaches, and the APIs Nerda
    /// answers for it (history, bookmarks…). An update that adds any of them
    /// is asked about again.
    static func grants(_ found: WKWebExtension, in folder: URL) -> [String] {
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: ".nerda-added")))) as? [String] ?? [])
        let declared = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? []
        let ours = Set(nerdaAnswered.map(\.0))
        var out = Set(found.requestedPermissions.map(\.rawValue).filter { !added.contains($0) })
        out.formUnion(found.allRequestedMatchPatterns.map { "site:" + $0.string })
        out.formUnion(declared.filter { ours.contains($0) && !added.contains($0) }.map { "nerda:" + $0 })
        return out.sorted()
    }

    /// Chrome's own APIs, which Nerda answers itself, and what each lets an
    /// extension do.
    static let nerdaAnswered: [(String, String)] = [
        ("userScripts", "Run scripts you add to it on websites"), ("history", "Read and change your history"),
        ("bookmarks", "Read and change your bookmarks"), ("downloads", "Manage your downloads"),
        ("privacy", "Change your privacy settings"), ("browsingData", "Clear your browsing data"),
        ("management", "See your other extensions"), ("notifications", "Show notifications"),
        ("sessions", "See your recently closed tabs"), ("topSites", "See your most visited sites"),
        ("downloads.open", "Open files it downloads"),
    ]

    /// What an extension wants, in words.
    static func describe(_ found: WKWebExtension, in folder: URL) -> [String] {
        var out: [String] = []
        // Leaving out what Nerda itself added to the manifest.
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: ".nerda-added")))) as? [String] ?? [])
        let declared = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? [])
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
            out.append("Read and change what's on " + hosts.prefix(4).joined(separator: ", ") + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [WKWebExtension.Permission: String] = [
            .tabs: "See your open tabs and their addresses",
            .cookies: "Read and change cookies",
            .webNavigation: "See where you go",
            .webRequest: "See the requests pages make",
            .declarativeNetRequest: "Block or change requests pages make",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to apps on this Mac",
            .scripting: "Run scripts in pages",
        ]
        for (permission, sentence) in words where found.requestedPermissions.contains(permission) && !added.contains(permission.rawValue) {
            out.append(sentence)
        }
        for (name, sentence) in nerdaAnswered where declared.contains(name) { out.append(sentence) }
        return out
    }

    private func ask(install name: String, wants: [String], icon: NSImage?) async -> Bool {
        await ask(
            "Add “\(name)” to Nerda?",
            detail: wants.isEmpty ? "It doesn't ask for anything special." : "It will be able to:\n• " + wants.joined(separator: "\n• "),
            icon: icon, yes: "Add Extension", no: "Cancel"
        )
    }

    /// An extension asking, through permissions.request, for one of the
    /// permissions Nerda answers itself.
    func ask(more names: String, context: WKWebExtensionContext) async -> Bool {
        await ask("asks for more access", detail: names, context: context)
    }

    private func ask(_ question: String, detail: String, context: WKWebExtensionContext) async -> Bool {
        await ask(
            "\(context.webExtension.displayName ?? "An extension") \(question)",
            detail: detail, icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            yes: "Allow", no: "Don't Allow"
        )
    }

    /// The last question asked, so the next waits for its answer.
    @ObservationIgnored private var question: Task<Bool, Never>?

    /// One question at a time, as a sheet on the window. An alert run
    /// modally would stop the whole browser (pages, downloads, every other
    /// extension) for as long as it waits, and an extension can ask when
    /// nobody is looking.
    private func ask(_ title: String, detail: String, icon: NSImage?, yes: String, no: String?) async -> Bool {
        let before = question
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await before?.value
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let icon { alert.icon = icon }
            alert.addButton(withTitle: yes)
            if let no { alert.addButton(withTitle: no) }
            guard let window = self?.browser?.window, window.isVisible else {
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        question = task
        return await task.value
    }

    /// Something went wrong that you asked for: said on the window.
    private func fail(_ message: String) {
        Task { _ = await ask("The extension wasn't added", detail: message, icon: nil, yes: "OK", no: nil) }
    }

    // MARK: - the buttons

    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
    }

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        let tab = activeAdapter
        return installed.compactMap { item in
            guard let context = contexts[item.id], let action = context.action(for: tab) else { return nil }
            return Button(
                id: item.id, name: item.name,
                label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badge: action.badgeText, enabled: action.isEnabled,
                pinned: item.pinned ?? false
            )
        }
    }

    func press(_ id: String) {
        guard let context = contexts[id], !ExtensionPopup.shared.closes(id) else { return }
        Self.clicked[id] = Date()
        if let tab = activeAdapter { context.userGesturePerformed(in: tab) }
        // An extension that asked for its button to open its side panel.
        if ExtensionShims.panelOnClick.contains(id), context.action(for: activeAdapter)?.presentsPopup != true {
            ExtensionShims.openPanel(context, owner: self)
            return
        }
        // A popup is opened here, at once. Left to WebKit, it builds a popup
        // of its own first, and closing that one for Nerda's lost the new
        // popup's first messages to its worker.
        if context.action(for: activeAdapter)?.presentsPopup == true, let url = currentPopupURL(for: context) {
            ExtensionPopup.shared.show(url, for: context, from: anchor(for: id))
            return
        }
        context.performAction(for: activeAdapter)
    }

    /// A key an extension registered for (its manifest's commands), unless
    /// it is one of Nerda's own: the browser's keys come first, as in Chrome.
    func take(_ event: NSEvent) -> Bool {
        guard !contexts.isEmpty, NSApp.mainMenu.map({ Self.claims($0, event) }) != true else { return false }
        for context in contexts.values where context.command(for: event) != nil {
            return context.performCommand(for: event)
        }
        return false
    }

    /// Whether a menu item answers to this key.
    private static func claims(_ menu: NSMenu, _ event: NSEvent) -> Bool {
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let key = event.charactersIgnoringModifiers?.lowercased()
        return menu.items.contains { item in
            if let submenu = item.submenu, claims(submenu, event) { return true }
            guard !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == key else { return false }
            // An upper-case key equivalent is a shifted one.
            var mask = item.keyEquivalentModifierMask.intersection(modifiers)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return mask == event.modifierFlags.intersection(modifiers)
        }
    }

    /// Right-click items extensions added, for a page's menu.
    func menuItems(for page: WKWebView) -> [NSMenuItem] {
        guard !contexts.isEmpty, let tab = browser?.tab(for: page) else { return [] }
        let adapter = adapter(for: tab)
        return installed.compactMap { contexts[$0.id] }.flatMap { $0.menuItems(for: adapter) }
    }

    // MARK: - the Chrome Web Store

    /// Tells the store's pages what is installed and what is on its way, so
    /// their button says Added to Nerda, or Adding….
    func tellStores() {
        for tab in browser?.tabs ?? [] { WebStore.tell(tab.page) }
    }
}

// MARK: - WebKit asks, the browser answers

extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        try Self.mayOpen(configuration.url ?? URL(string: "about:blank")!)
        let tab = withAnimation(.slide) {
            browser.open(configuration.url ?? URL(string: "about:blank")!, inBackground: !configuration.shouldBeActive)
        }
        if configuration.shouldBePinned { browser.setPinned(true, tab.id) }
        return adapter(for: tab)
    }

    /// One window: a new window's pages become tabs in it.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let browser else { return nil }
        // A private window isn't something an extension can have here: made
        // as a tab of this window, its pages would land in your History and
        // cookies while the extension believed them private. Refused, as
        // Chrome refuses when incognito isn't allowed.
        if configuration.shouldBePrivate {
            throw NSError(domain: "Nerda", code: 2, userInfo: [NSLocalizedDescriptionKey: "Private windows can't be opened by extensions."])
        }
        for url in configuration.tabURLs { try Self.mayOpen(url) }
        for (index, url) in configuration.tabURLs.enumerated() {
            withAnimation(.slide) { _ = browser.open(url, inBackground: index > 0 || !configuration.shouldBeFocused) }
        }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        browser?.open(url)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return await ask("asks for more access", detail: detail, context: extensionContext) ? (permissions, nil) : ([], nil)
    }

    /// WebKit asks this the way Safari does: whenever an extension reaches
    /// for a page it has no host permission for (listing tabs, running a
    /// script in one), often with nobody having touched anything. Chrome
    /// never asks there: the extension has the sites its manifest named, the
    /// page it was clicked on (activeTab), and those it asked for through
    /// permissions.request. So neither does Nerda.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        // Extension pages are never given, so never asked about.
        let wanted = matchPatterns.filter { !Self.reachesExtensions($0) }
        guard !wanted.isEmpty else { return ([], nil) }
        let all = wanted.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "every website" : wanted.map(\.string).sorted().joined(separator: ", ")
        guard await ask("wants to read and change \(what)", detail: "Until you remove the extension.", context: extensionContext) else { return ([], nil) }
        // Given only once this returns: fenced again right after.
        DispatchQueue.main.async { Self.fence(extensionContext) }
        return (wanted, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// The popup page, in a popover of Nerda's own (ExtensionPopup says
    /// why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Self.popupURL(for: context)
        action.closePopup()
        guard let url else { return }
        ExtensionPopup.shared.show(url, for: context, from: anchor(for: context.uniqueIdentifier))
    }

    /// `runtime.sendNativeMessage`. To "nerda": the APIs WebKit lacks,
    /// answered by this app. To anything else: a Chrome native messaging host
    /// installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        guard let host = applicationIdentifier, host != ExtensionShims.application else {
            return try await ExtensionShims.answer(message, from: extensionContext, owner: self)
        }
        let id = extensionContext.uniqueIdentifier
        guard talksToApps.contains(id) else {
            throw ExtensionNative.Refused(why: "Access to native messaging requires the nativeMessaging permission.")
        }
        do {
            return try await ExtensionNative.send(message, to: host, from: id)
        } catch {
            // An extension asking an app that isn't there over and over (a
            // retry loop) is answered slowly past a dozen times a second, so
            // it can't swamp the browser.
            let key = id + "→" + host, now = Date()
            failures[key] = (failures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
            if (failures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, from: extensionContext.uniqueIdentifier)
            return
        }
        // The port a worker's shim opens only to find what ports share; it
        // lets go at once.
        if port.applicationIdentifier == ExtensionShims.application { return }
        guard talksToApps.contains(extensionContext.uniqueIdentifier) else {
            throw ExtensionNative.Refused(why: "Access to native messaging requires the nativeMessaging permission.")
        }
        try ExtensionNative.connect(port, from: extensionContext.uniqueIdentifier)
    }
}

// MARK: - adapters

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    private var browser: Browser? { owner.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab else { return NSNotFound }
        return owner.place(of: tab) ?? NSNotFound
    }

    /// A tab showing another extension's page gives an extension nothing of
    /// it: no view to run a script in, no address, no picture, whatever it
    /// was granted (see Extensions.reachesExtensions).
    private func sealed(_ context: WKWebExtensionContext) -> Bool {
        Extensions.othersPage(tab?.page?.url, for: context) || Extensions.othersPage(tab?.site, for: context)
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { sealed(context) ? nil : tab?.page }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { sealed(context) ? nil : tab?.site }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab != nil && tab?.id == browser?.selectedID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.page?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.page?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.setPinned(pinned, tab.id)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.page?.pageZoom = CGFloat(zoomFactor)
    }

    /// The tab makes its page anew when the address is another kind: a
    /// website sent to an extension's page, as 1Password does once a sign-in
    /// in its tab has added the account, and back (see Tab.go).
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        try Extensions.mayOpen(url)
        tab?.go(to: url)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload(fromOrigin: fromOrigin) }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.page?.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.page?.goForward() }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.select(tab.id)
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { return }
        withAnimation(.slide) { browser.close(tab.id) }
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let page = tab?.page, !sealed(context) else { return nil }
        return try await page.takeSnapshot(configuration: configuration)
    }
}

final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    init(owner: Extensions) { self.owner = owner }

    private var nsWindow: NSWindow? { owner.browser?.window }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        owner.visibleTabs.map(owner.adapter(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { owner.activeAdapter }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate()
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}
