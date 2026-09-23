import AppKit
import SwiftUI

/// The whole window: the sidebar, and the page beside it. With the sidebar
/// collapsed the page takes the whole window, and the sidebar comes out over
/// it while the pointer is at the window's left edge.
struct BrowserView: View {
    let browser: Browser
    let window: NSWindow

    /// The collapsed sidebar, out over the page.
    @State private var peeking = false
    @State private var overPeek = false
    @State private var downloadsShown = false

    var body: some View {
        HStack(spacing: 0) {
            if browser.sidebarOpen {
                Sidebar(browser: browser, pinned: true, downloadsShown: $downloadsShown)
                    .transition(.move(edge: .leading))
                    // Its tooltip reaches out over the page.
                    .zIndex(1)
            }
            ZStack {
                Palette.ground
                if let tab = browser.selected {
                    PageView(tab: tab, takesFocus: !browser.commandBarOpen)
                        .overlay {
                            if let failure = tab.failure { PageFailure(message: failure.message) }
                        }
                        .id(tab.id)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if browser.findBarOpen, browser.selected != nil {
                    FindBar(browser: browser)
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .overlay(alignment: .leading) {
            if !browser.sidebarOpen { peek }
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
                            go: { url in
                                withAnimation(.slide) { browser.open(url) }
                                browser.hideCommandBar()
                            },
                            dismiss: browser.hideCommandBar
                        )
                        // Pinned by its top edge, a third of the way down, so the
                        // field stays put while the list under it grows and shrinks.
                        .padding(.top, window.size.height * 0.3)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .ignoresSafeArea()
        // The traffic lights belong to the sidebar: with it gone, nothing sits on the page.
        .onChange(of: browser.sidebarOpen || peeking, initial: true) { _, shown in
            window.showTrafficLights(shown)
        }
        // Pinning it, or going somewhere new from it, puts the floating one away.
        .onChange(of: browser.sidebarOpen) { peeking = false }
        .onChange(of: browser.commandBarOpen) { if browser.commandBarOpen { peeking = false } }
        // Leaving it puts it away, after a moment, so brushing past the edge
        // doesn't; the downloads list open from it holds it out.
        .task(id: peeking && !overPeek && !downloadsShown) {
            guard peeking, !overPeek, !downloadsShown else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { withAnimation(.slide) { peeking = false } }
        }
    }

    @ViewBuilder private var peek: some View {
        if peeking {
            Sidebar(browser: browser, pinned: false, downloadsShown: $downloadsShown)
                .onHover { overPeek = $0 }
                .transition(.move(edge: .leading))
        } else {
            // A sliver along the edge, narrow enough not to get in the page's way.
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 { withAnimation(.slide) { peeking = true } } }
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
            context.duration = 0.2
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
        withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = true }
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
    /// goes, not the page behind it.
    func closeSelectedTab() {
        if commandBarOpen { return hideCommandBar() }
        guard let selectedID else { return }
        withAnimation(.slide) { close(selectedID) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Tabs are ours; no system tab bar, and no Show Tab Bar items in the menus.
NSWindow.allowsAutomaticWindowTabbing = false

let browser = Browser()
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
// which brings the lights down to the middle of the sidebar's top row.
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
app.activate()
app.run()
