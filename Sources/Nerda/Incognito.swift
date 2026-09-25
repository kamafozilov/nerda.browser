import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

/// Nerda's windows: the regular one, made at launch (main.swift), and any
/// incognito ones (⇧⌘N). Incognito windows share one store in memory, as
/// Chrome's do: signed in to a site in one, you are in all of them, until the
/// last one closes and takes the store, with every cookie in it, along.
///
/// They lock together, as Safari's private windows do: at once when the Mac
/// locks its screen or sleeps, and once Nerda has been in the background for
/// a minute. Locked, each shows only its lock, until Touch ID or the Mac's
/// password opens them again.
enum Windows {
    static var regular: BrowserWindow!
    /// Each open incognito window, with what looks after it.
    private static var incognito: [AppDelegate] = []
    /// How long Nerda can be in the background before incognito locks.
    // ponytail: fixed; a setting if a minute turns out too short or too long.
    static let lockAfter: Duration = .seconds(60)
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
            withAnimation(.slide) { last.browser.open(url) }
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
                lockTimer = Task {
                    try? await Task.sleep(for: lockAfter)
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
    static func showRegular() -> Browser {
        if !regular.isVisible { regular.browser.restore(from: Session.file) }
        regular.makeKeyAndOrderFront(nil)
        return regular.browser
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
