import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

/// Nerda's windows: the regular one, Personal's, made at launch (main.swift),
/// one for each other profile, made as it is first opened (File › New
/// Window), and any incognito ones (⇧⌘N). Incognito windows share one store
/// in memory, as Chrome's do: signed in to a site in one, you are in all of
/// them, until the last one closes and takes the store, with every cookie in
/// it, along.
///
/// They lock together, as Safari's private windows do: at once when the Mac
/// locks its screen or sleeps, and once Nerda has been in the background for
/// a minute (Settings › Security & Privacy). Locked, each shows only its lock, until Touch ID or the Mac's
/// password opens them again.
enum Windows {
    static var regular: BrowserWindow!
    /// Each other profile's window, with what looks after it: kept once made,
    /// closed or not, as the regular one is.
    private static var profiles: [AppDelegate] = []
    /// Each open incognito window, with what looks after it.
    private static var incognito: [AppDelegate] = []
    /// Each open secondary window, a tab was moved out to, with what looks after it.
    private static var secondary: [AppDelegate] = []
    private static var lockTimer: Task<Void, Never>?
    private static var watching = false

    static var locked: Bool { incognito.first?.browser.locked ?? false }

    /// ⇧⌘N: a new incognito window. With a link (Open Link in Incognito
    /// Window), a tab for it in the incognito window last opened, as in
    /// Chrome, or a window of its own. Locked, only once unlocked.
    static func openIncognito(_ url: URL? = nil) {
        if locked {
            Task { if await unlock() { openIncognito(url) } }
            return
        }
        watchForAway()
        if let url, let last = incognito.last {
            withAnimation(.slide) { _ = last.browser.open(url) }
            return last.window.makeKeyAndOrderFront(nil)
        }
        let browser = Browser(dataStore: incognito.first?.browser.dataStore ?? .nonPersistent())
        if let url { browser.open(url) } else { browser.add(Tab()) }
        let window = BrowserWindow(browser: browser)
        let delegate = AppDelegate(window: window, browser: browser)
        window.delegate = delegate
        incognito.append(delegate)
        window.makeKeyAndOrderFront(nil)
    }

    /// Hides every incognito window behind its lock, and takes the keyboard
    /// from its page, so nothing typed reaches it.
    static func lock() {
        for delegate in incognito where !delegate.browser.locked {
            let browser = delegate.browser
            browser.exitPageFullscreen()
            browser.commandBarOpen = false
            browser.editingAddress = false
            browser.findBarOpen = false
            browser.passwordChoices = nil
            browser.locked = true
            delegate.window.makeFirstResponder(nil)
        }
    }

    /// Asks for Touch ID, or the Mac's password, and opens the incognito
    /// windows once given. A Mac with neither has nothing to ask for.
    @discardableResult
    static func unlock() async -> Bool {
        guard locked else { return true }
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                     localizedReason: "unlock your incognito windows")) == true
            else { return false }
        }
        withAnimation(.easeOut(duration: 0.2)) {
            for delegate in incognito { delegate.browser.locked = false }
        }
        (NSApp.mainWindow as? BrowserWindow)?.browser.focusPage()
        return true
    }

    /// "Unlock with Touch ID" on a Mac that has it; "Unlock" asks for the password.
    static let unlockTitle: String = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Unlock with Touch ID" : "Unlock"
    }()

    /// Listens, from the first incognito window on, for Nerda going to the
    /// background and coming back, and for the Mac locking or sleeping.
    private static func watchForAway() {
        guard !watching else { return }
        watching = true
        let app = NotificationCenter.default
        app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                lockTimer?.cancel()
                // Watched for good once the first window opened; with none
                // open now there is nothing to lock.
                guard !incognito.isEmpty, let after = IncognitoAutoLock.current.delay else { return }
                lockTimer = Task {
                    try? await Task.sleep(for: after)
                    if !Task.isCancelled { lock() }
                }
            }
        }
        app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lockTimer?.cancel() }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lock() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { lock() }
        }
    }

    /// An incognito window is closing: let go of it, once AppKit is done
    /// closing it. The window's view holds on to the window, and would keep
    /// it, its browser and the store it uses, so it goes first.
    static func closed(_ delegate: AppDelegate) {
        DispatchQueue.main.async {
            delegate.window.contentView = nil
            incognito.removeAll { $0 === delegate }
        }
    }

    /// The regular window, brought back with its tabs if it was closed: for
    /// what an incognito window leaves to it (settings, history).
    static func showRegular() -> Browser { show(.main) }

    /// The window what `browser`'s doesn't keep (settings, history, bookmarks)
    /// opens in: its profile's own, Personal's for incognito.
    static func home(of browser: Browser) -> Browser { show(browser.isPrivate ? .main : browser.profile) }

    /// Move to New Window: a window of its own for a tab, page and all,
    /// filling `screen`. Incognito, another incognito window; otherwise a
    /// secondary one, with tabs only, saved with the profile's
    /// (`Windows/<id>.json`) to open again at the next launch.
    static func moveToNewWindow(_ id: Tab.ID, from browser: Browser, on screen: NSScreen?) {
        guard browser.tabs.contains(where: { $0.id == id }) else { return }
        let moved = browser.isPrivate ? Browser(dataStore: browser.dataStore)
            : Browser(profile: browser.profile, secondary: true)
        let window = BrowserWindow(browser: moved, screen: screen)
        let delegate = AppDelegate(window: window, browser: moved)
        window.delegate = delegate
        if browser.isPrivate {
            incognito.append(delegate)
        } else {
            secondary.append(delegate)
            moved.sessionFile = windowsFolder(of: browser.profile).appending(path: "\(UUID().uuidString).json")
        }
        browser.move(id, to: moved)
        window.makeKeyAndOrderFront(nil)
    }

    /// The other windows a tab of `browser`'s can be moved to: those of the
    /// same browsing, in front first.
    static func others(of browser: Browser) -> [Browser] {
        NSApp.orderedWindows.compactMap { ($0 as? BrowserWindow)?.browser }
            .filter { $0 !== browser && $0.dataStore === browser.dataStore && !$0.tabs.isEmpty && !$0.locked }
    }

    /// For Move Tab to New Window from the menu: the next display, if there
    /// is more than one, as that is what a window of its own is mostly for.
    static func nextScreen(after window: NSWindow?) -> NSScreen? {
        let screens = NSScreen.screens
        guard let current = window?.screen, let index = screens.firstIndex(of: current) else { return NSScreen.main }
        return screens[(index + 1) % screens.count]
    }

    /// Window › Merge All Windows: every secondary window's tabs back in the
    /// profile's own window, as Safari merges its windows.
    static func merge(into profile: Profile) {
        let home = show(profile)
        for delegate in secondary where delegate.browser.profile === profile {
            // Each goes where a new tab would, above the rest down the side, after them across the top.
            let tabs = TabStyle.current == .horizontal ? delegate.browser.tabs : delegate.browser.tabs.reversed()
            for tab in tabs { delegate.browser.move(tab.id, to: home) }
        }
    }

    static func hasSecondary(of profile: Profile) -> Bool { secondary.contains { $0.browser.profile === profile } }

    /// A secondary window is closing: its tabs go to the profile's own
    /// window's Recently Closed, for ⇧⌘T to bring back, and its file goes,
    /// so it doesn't open again at the next launch.
    static func closedSecondary(_ delegate: AppDelegate) {
        let browser = delegate.browser
        let file = browser.sessionFile
        browser.pendingSave?.cancel()
        browser.sessionFile = nil
        if let home = window(of: browser.profile, making: false)?.browser {
            let closed = browser.tabs.compactMap(\.saved).filter { $0.url != nil }.map { Session.ClosedTab(tab: $0, index: 0) }
            home.recentlyClosed = Array((home.recentlyClosed + closed).suffix(25))
            home.sessionChanged()
        }
        browser.closeAll()
        if let file { Session.writer.async { try? FileManager.default.removeItem(at: file) } }
        DispatchQueue.main.async {
            delegate.window.contentView = nil
            secondary.removeAll { $0 === delegate }
        }
    }

    /// At launch, each secondary window left open, with its tabs, on the
    /// display it was on, behind the regular one.
    static func reopenSecondary() {
        for profile in Profiles.shared.all {
            let folder = windowsFolder(of: profile)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
                let file = folder.appending(path: name)
                guard let session = Session.read(from: file), !session.tabs.isEmpty else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let screen = session.frame.flatMap { frame in
                    NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                }
                let browser = Browser(profile: profile, secondary: true)
                browser.restore(session, from: file)
                let window = BrowserWindow(browser: browser, screen: screen ?? NSScreen.main)
                let delegate = AppDelegate(window: window, browser: browser)
                window.delegate = delegate
                secondary.append(delegate)
                window.order(.below, relativeTo: regular.windowNumber)
            }
        }
    }

    private static func windowsFolder(of profile: Profile) -> URL { profile.folder.appending(path: "Windows") }

    /// A profile's window in front: made the first time, and brought back
    /// with its tabs if it was closed.
    @discardableResult
    static func show(_ profile: Profile) -> Browser {
        let window = window(of: profile)
        if !window.isVisible { window.browser.restore(from: profile.sessionFile) }
        window.makeKeyAndOrderFront(nil)
        mark(profile, open: true)
        return window.browser
    }

    private static func window(of profile: Profile) -> BrowserWindow { window(of: profile, making: true)! }

    private static func window(of profile: Profile, making: Bool) -> BrowserWindow? {
        if profile.isMain { return regular }
        if let made = profiles.lazy.compactMap({ $0.window as? BrowserWindow }).first(where: { $0.browser.profile === profile }) {
            return made
        }
        guard making else { return nil }
        let browser = Browser(profile: profile)
        let window = BrowserWindow(browser: browser)
        let delegate = AppDelegate(window: window, browser: browser)
        window.delegate = delegate
        profiles.append(delegate)
        return window
    }

    /// At launch, each other profile's window that was open, with its tabs,
    /// behind the regular one. With Personal alone, none.
    static func reopenProfiles() {
        for profile in Profiles.shared.all where profile.open {
            let window = window(of: profile)
            window.browser.restore(from: profile.sessionFile)
            window.order(.below, relativeTo: regular.windowNumber)
        }
    }

    /// Whether its window opens again at the next launch, written as it
    /// changes. Personal's always does.
    static func mark(_ profile: Profile, open: Bool) {
        guard !profile.isMain, profile.open != open, Profiles.shared.all.contains(where: { $0 === profile }) else { return }
        profile.open = open
        Profiles.shared.save()
    }

    /// Its window closed and let go of, before the profile is deleted:
    /// WebKit removes a store only once no page uses it.
    static func forget(_ profile: Profile) {
        for delegate in secondary where delegate.browser.profile === profile { delegate.window.close() }
        guard let index = profiles.firstIndex(where: { $0.browser.profile === profile }) else { return }
        let delegate = profiles.remove(at: index)
        delegate.window.close()
        delegate.window.delegate = nil
        delegate.window.contentView = nil
    }

    /// Every window's browser but incognito ones': what is saved as Nerda quits.
    static var browsers: [Browser] {
        [regular?.browser].compactMap(\.self) + profiles.map(\.browser) + secondary.map(\.browser)
    }

    /// The window of a profile used last, in front of the others, where links
    /// from other apps open, as in Safari; none with none showing.
    static var lastUsed: BrowserWindow? {
        NSApp.orderedWindows.lazy.compactMap { $0 as? BrowserWindow }.first { $0.isVisible && !$0.browser.isPrivate }
    }

    /// The names the Window menu lists them by: with profiles, each its
    /// profile's, as one is added, renamed or deleted.
    static func retitle() {
        for case let window as BrowserWindow in NSApp.windows { window.title = BrowserWindow.title(of: window.browser) }
    }
}

extension EnvironmentValues {
    /// Inside an incognito window: site icons are fetched without leaving
    /// anything on disk (see `Favicons.load`).
    @Entry var incognito = false
}

/// A hat over a pair of glasses, as browsers mark incognito, drawn in the
/// foreground colour.
struct IncognitoMark: View {
    var size: CGFloat = 16

    var body: some View {
        Glyph()
            .stroke(style: StrokeStyle(lineWidth: max(size / 13, 1.2), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// On a 24-point grid: the hat's crown and brim, then the glasses.
    nonisolated private struct Glyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 5, y: 10.5))
            path.addLine(to: CGPoint(x: 7, y: 4.6))
            path.addQuadCurve(to: CGPoint(x: 9, y: 3.2), control: CGPoint(x: 7.4, y: 3.2))
            path.addLine(to: CGPoint(x: 15, y: 3.2))
            path.addQuadCurve(to: CGPoint(x: 17, y: 4.6), control: CGPoint(x: 16.6, y: 3.2))
            path.addLine(to: CGPoint(x: 19, y: 10.5))
            path.move(to: CGPoint(x: 2.5, y: 10.5))
            path.addLine(to: CGPoint(x: 21.5, y: 10.5))
            path.addEllipse(in: CGRect(x: 4.2, y: 13.2, width: 6.6, height: 6.6))
            path.addEllipse(in: CGRect(x: 13.2, y: 13.2, width: 6.6, height: 6.6))
            path.move(to: CGPoint(x: 10.8, y: 16.3))
            path.addQuadCurve(to: CGPoint(x: 13.2, y: 16.3), control: CGPoint(x: 12, y: 15.3))
            let scale = min(rect.width, rect.height) / 24
            return path.applying(CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
    }
}

/// An incognito window's new tab: on the plain dark page, in place of a
/// picture, the incognito mark, where to go, and what incognito keeps and
/// doesn't. The field sits where a regular new tab's does, a third of the
/// way down, and comes last, so its suggestions go over the words under it.
struct IncognitoPage: View {
    let browser: Browser

    /// The new tab's field, as `CommandBar` draws it.
    private static let field: CGFloat = 52

    var body: some View {
        GeometryReader { page in
            let top = page.size.height * 0.3
            ZStack(alignment: .top) {
                IncognitoMark(size: 56)
                    .foregroundStyle(Palette.muted)
                    .padding(.top, top - 56 - 32)
                Text("""
                    You're browsing privately. Nerda doesn't keep the pages you visit here in your history, \
                    and their cookies and site data go when you close every incognito window. \
                    Files you download and passwords you save are kept. \
                    Sites you visit, your employer or school, and your internet provider can still see what you do.
                    """)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, top + Self.field + 28)
                CommandBar(
                    text: "",
                    place: .newTab,
                    go: { browser.selected?.go(to: $0) },
                    dismiss: {},
                    requests: browser.newTabRequests,
                    history: browser.history
                )
                // On the plain page, an edge to find it by, in the accent.
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Palette.incognitoAccent.opacity(0.45)))
                .padding(.horizontal, 12)
                .padding(.top, top)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Over a locked incognito window, the whole of it: nothing of its tabs shows
/// until it is unlocked. Return unlocks, as the button does.
struct IncognitoLock: View {
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            IncognitoMark(size: 48)
                .foregroundStyle(Palette.incognitoAccent)
            Text("Incognito Is Locked")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 20)
            Text("Your incognito tabs are hidden while you're away.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
            Button {
                asking = true
                Task {
                    await Windows.unlock()
                    asking = false
                }
            } label: {
                Text(Windows.unlockTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(Capsule().fill(Palette.incognitoAccent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Windows.unlockTitle)
            .focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
            .disabled(asking)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // It still moves the window, as the glass it covers does.
        .background { Palette.ground.titleBar() }
        .transition(.opacity)
    }
}
