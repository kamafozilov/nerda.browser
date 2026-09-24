import AppKit
import SwiftUI

/// The whole window: the sidebar, and the page beside it, on the window's
/// glass: the page and its address bar as one card with rounded corners,
/// clear of the window's edges. With the sidebar collapsed the card takes
/// the whole window, and the sidebar comes out over it while the pointer is
/// at the window's left edge.
///
/// The sidebar always slides over the page, never alongside it, and the page
/// never changes size for it: WebKit redraws a resized page a frame or more
/// late, and the gap shows as a blank strip. The page stays the size of the
/// window and is told how much of it the sidebar covers, and lays itself out
/// beside it; its corners are cut where it shows. (Before macOS 26, which
/// can't be told, the page is resized once, where the sidebar hides it: as
/// the sidebar starts to go, and once it has fully come.)
struct BrowserView: View {
    let browser: Browser
    let window: NSWindow

    /// The collapsed sidebar, out over the page.
    @State private var peeking = false
    @State private var overPeek = false
    @State private var downloadsShown = false
    /// The page leaves room for the sidebar.
    @State private var docked = true
    @AppStorage("sidebarWidth") private var sidebarWidth = Sidebar.defaultWidth
    /// The window went full screen for a page, and comes back with it.
    @State private var fullScreenForPage = false

    /// A page shows one of its elements (a video) over the whole window: the
    /// sidebar keeps out of the way until it is done.
    private var pageFullscreen: Bool { browser.fullscreenTab != nil }
    private var room: CGFloat { docked && !pageFullscreen ? sidebarWidth : 0 }
    private var sidebarShown: Bool { (browser.sidebarOpen || peeking) && !pageFullscreen }

    /// The page, and the address bar over it, sit as one card on the window's
    /// glass, clear of its edges by this much, their corners rounded by this.
    static let margin: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    private var margin: CGFloat { pageFullscreen ? 0 : Self.margin }
    /// Where the card's visible left edge is: past the docked sidebar, or the margin.
    private var inset: CGFloat { max(room, margin) }
    /// How much of the page lies under the docked sidebar (macOS 26, where
    /// the page is told rather than made narrower).
    private var covered: CGFloat { PageView.canBeCovered ? inset - margin : 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            // The window's glass, around the card as under the sidebar; it
            // moves the window, as the title bar under it would.
            SidebarGlass()
                .overlay { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }

            page
                .padding(.top, pageFullscreen ? 0 : margin + AddressBar.height)
                .padding([.bottom, .trailing], margin)
                .padding(.leading, PageView.canBeCovered ? margin : inset)
                // The page's room changes in one step, however it is asked for.
                .animation(nil, value: docked)

            if !pageFullscreen {
                // Beside the sidebar, and under it while it is out over the page.
                AddressBar(browser: browser)
                    .padding(.leading, inset)
                    .padding([.top, .trailing], margin)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .animation(nil, value: docked)
            }

            // Always there, slid off to the left when not wanted, rather than
            // added and taken away, so it comes back as it was left (scrolled
            // where it was) without being built again.
            Sidebar(browser: browser, pinned: browser.sidebarOpen, downloadsShown: $downloadsShown, width: $sidebarWidth)
                .onHover { overPeek = $0 }
                // Far enough that its shadow goes too.
                .offset(x: sidebarShown ? 0 : -(sidebarWidth + 32))
                .allowsHitTesting(sidebarShown)
                .accessibilityHidden(!sidebarShown)

            if !sidebarShown, !pageFullscreen {
                // A sliver along the edge, narrow enough not to get in the page's way.
                Color.clear
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { if $0 { withAnimation(.slide) { peeking = true } } }
            }
        }
        .overlay {
            if browser.commandBarOpen {
                GeometryReader { window in
                    ZStack(alignment: .top) {
                        // A click anywhere outside the bar puts it away.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: browser.hideCommandBar)
                        CommandBar(
                            text: "",
                            inline: false,
                            go: { url in
                                withAnimation(.slide) { browser.open(url) }
                                browser.hideCommandBar()
                            },
                            dismiss: browser.hideCommandBar,
                            requests: browser.commandBarRequests
                        )
                        .padding(.horizontal, 12)
                        // Pinned by its top edge, a third of the way down, so the
                        // field stays put while the list under it grows and shrinks.
                        .padding(.top, window.size.height * 0.3)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .ignoresSafeArea()
        // The traffic lights belong to the sidebar: they go as soon as it starts
        // to, and come once it has all but arrived, so that nothing sits on the
        // page on its own and the sidebar's toggle never slides across them.
        .task(id: sidebarShown) {
            if sidebarShown {
                try? await Task.sleep(for: .milliseconds(180))
                if Task.isCancelled { return }
            }
            window.showTrafficLights(sidebarShown)
        }
        .onChange(of: browser.sidebarOpen) { _, open in
            // Pinning it puts the floating one away (it stays where it is, now pinned).
            peeking = false
            // Going: the page takes the whole window at once, under the sidebar
            // as it slides off.
            if !open { docked = false }
        }
        // Coming: the page makes room once the sidebar has slid all the way in
        // over it (at once, if it came without animation).
        .transaction(value: browser.sidebarOpen) { transaction in
            guard browser.sidebarOpen else { return }
            transaction.addAnimationCompletion { docked = browser.sidebarOpen }
        }
        .onChange(of: browser.commandBarOpen) { if browser.commandBarOpen { peeking = false } }
        // As Chrome does: the window goes full screen with the page, unless it
        // already was, and comes back with it. Asked again once a transition
        // ends, as macOS ignores what is asked during one.
        .onChange(of: pageFullscreen) { matchWindowToPage() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification, object: window)) { _ in
            matchWindowToPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification, object: window)) { _ in
            fullScreenForPage = false
            matchWindowToPage()
        }
        // Leaving full screen from the window (its green button, ⌃⌘F) takes the page out too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification, object: window)) { _ in
            fullScreenForPage = false
            browser.exitPageFullscreen()
        }
        // Leaving it puts it away, after a moment, so brushing past the edge
        // doesn't; the downloads list open from it holds it out.
        .task(id: peeking && !overPeek && !downloadsShown) {
            guard peeking, !overPeek, !downloadsShown else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { withAnimation(.slide) { peeking = false } }
        }
    }

    private func matchWindowToPage() {
        let windowFullScreen = window.styleMask.contains(.fullScreen)
        if pageFullscreen, !windowFullScreen {
            fullScreenForPage = true
            window.toggleFullScreen(nil)
        } else if !pageFullscreen, fullScreenForPage, windowFullScreen {
            window.toggleFullScreen(nil)
        }
    }

    private var page: some View {
        let radius = pageFullscreen ? 0 : Self.cornerRadius
        return ZStack {
            Palette.ground
            PageView(
                tabs: browser.tabs,
                selected: browser.selected,
                takesFocus: !browser.commandBarOpen,
                coveredLeading: covered
            )
            if let failure = browser.selected?.failure {
                // Switched in with the tab, as the page is: faded, it would
                // show the blank page under it, and linger over the next.
                PageFailure(message: failure.message)
                    .padding(.leading, covered)
                    .background(Palette.ground)
                    .transition(.identity)
            }
        }
        // The card's lower corners, where it shows: past what the sidebar covers.
        .mask {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .padding(.leading, covered)
        }
        .overlay(alignment: .topTrailing) {
            if browser.findBarOpen, browser.selected != nil {
                FindBar(browser: browser)
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .top) {
            if let offer = browser.passwordOffer, offer.tab == browser.selectedID {
                PasswordOfferBar(browser: browser, offer: offer)
                    .padding(.top, 12)
                    .padding(.leading, covered)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .topLeading) {
            if let choices = browser.passwordChoices, choices.tab == browser.selectedID, !browser.commandBarOpen {
                PasswordChoicesView(browser: browser, choices: choices)
                    .offset(x: covered + choices.spot.minX, y: choices.spot.maxY + 4)
            }
        }
    }
}

extension NSWindow {
    /// Faded rather than switched, and hidden once faded, so an invisible
    /// close button can't be clicked on the page.
    func showTrafficLights(_ shown: Bool) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(standardWindowButton)
        if shown { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.15 : 0.1
            buttons.forEach { $0.animator().alphaValue = shown ? 1 : 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                buttons.forEach { $0.isHidden = $0.alphaValue == 0 }
            }
        }
    }
}

/// What the menu and the buttons both do, animated the same way from either.
extension Browser {
    func showCommandBar() {
        withAnimation(.easeOut(duration: 0.14)) {
            editingAddress = false
            commandBarOpen = true
        }
        commandBarRequests += 1
    }

    /// ⌘L, or a click on the address: the address made editable where it is,
    /// to take the tab on screen somewhere else. With no tab, a new one.
    func editAddress() {
        guard selected != nil else { return showCommandBar() }
        exitPageFullscreen()
        if commandBarOpen { withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = false } }
        editingAddress = true
        commandBarRequests += 1
    }

    /// The address back as it was, and the keyboard back on the page.
    func endAddressEdit() {
        guard editingAddress else { return }
        editingAddress = false
        if let page = selected?.webView { page.window?.makeFirstResponder(page) }
    }

    func hideCommandBar() {
        withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = false }
        // The keyboard goes back to the page it was taken from. A page that is
        // only now opening has no window yet, and takes it once it does.
        if let page = selected?.webView { page.window?.makeFirstResponder(page) }
    }

    func showFindBar() {
        withAnimation(.easeOut(duration: 0.14)) { findBarOpen = true }
        findRequests += 1
    }

    /// Puts the find bar away, and the keyboard back on the page.
    func hideFindBar() {
        withAnimation(.easeOut(duration: 0.14)) { findBarOpen = false }
        if let page = selected?.webView { page.window?.makeFirstResponder(page) }
    }

    func toggleSidebar() {
        withAnimation(.slide) { sidebarOpen.toggle() }
    }

    /// ⌘W. With the command bar up it is the new tab being asked for that
    /// goes, not the page behind it. A pinned tab stays, as in Safari: the
    /// screen goes to the tabs below it instead.
    func closeSelectedTab() {
        if commandBarOpen { return hideCommandBar() }
        guard let selected else { return }
        if selected.isPinned {
            if let next = tabs.first(where: { !$0.isPinned }) { selectedID = next.id }
            return
        }
        let id = selected.id
        withAnimation(.slide) { close(id) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Tabs are ours; no system tab bar, and no Show Tab Bar items in the menus.
NSWindow.allowsAutomaticWindowTabbing = false

let browser = Browser()
History.shared.load(from: History.file)
Favicons.shared.folder = Favicons.folder
browser.restore(from: Session.file)
let menu = AppMenu(browser: browser)
menu.install()

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
// No visible title bar: the sidebar runs up to the top edge and the traffic
// lights sit on it. An empty unified toolbar makes the title bar 52pt tall,
// which brings the lights down to the middle of the sidebar's top row, level
// with the middle of the address bar (see `Sidebar.topRow`).
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.toolbar = NSToolbar()
window.toolbarStyle = .unified
window.isReleasedWhenClosed = false
window.contentMinSize = NSSize(width: 640, height: 420)
window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
// Every launch, the whole screen short of the menu bar and Dock. Not the frame
// it was left at: one stray resize would otherwise stick for good.
if let screen = NSScreen.main {
    window.setFrame(screen.visibleFrame, display: false)
}
window.makeKeyAndOrderFront(nil)

let delegate = AppDelegate(window: window, browser: browser)
app.delegate = delegate
window.delegate = delegate
// SIGTERM (`kill`, and watch.sh putting in a new build) would end the app on
// the spot; the tabs and history are saved first.
signal(SIGTERM, SIG_IGN)
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminated.setEventHandler {
    MainActor.assumeIsolated { delegate.save() }
    exit(0)
}
terminated.resume()

app.activate()
app.run()
