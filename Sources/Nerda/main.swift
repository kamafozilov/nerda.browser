import AppKit
import SwiftUI

/// The whole window: the sidebar, and the page beside it.
struct BrowserView: View {
    let browser: Browser

    var body: some View {
        HStack(spacing: 0) {
            if browser.sidebarOpen {
                Sidebar(browser: browser, newTab: browser.showCommandBar).transition(.move(edge: .leading))
            }
            ZStack {
                Palette.ground
                // The page goes here; for now just its address. Keyed by the
                // tab, so each one gets its own view, as each will get its own page.
                if let tab = browser.selected {
                    Text(tab.url.absoluteString)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.muted)
                        .id(tab.id)
                        .transition(.opacity)
                }
            }
        }
        // The title bar is under the top row, so the window is dragged from there.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: Sidebar.topRow)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .overlay(alignment: .topLeading) {
            SidebarToggle(open: browser.sidebarOpen, toggle: browser.toggleSidebar)
                // Open: at the sidebar's right edge. Closed: past the traffic
                // lights, which end at 79pt.
                .padding(.leading, browser.sidebarOpen ? Sidebar.width - 10 - 28 : 86)
                .frame(height: Sidebar.topRow)
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
    }
}

/// What the menu and the buttons both do, animated the same way from either.
extension Browser {
    func showCommandBar() {
        withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = true }
    }

    func hideCommandBar() {
        withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = false }
    }

    func toggleSidebar() {
        withAnimation(.slide) { sidebarOpen.toggle() }
    }

    func closeSelectedTab() {
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
window.contentView = NSHostingView(rootView: BrowserView(browser: browser))
// Every launch, the whole screen short of the menu bar and Dock. Not the frame
// it was left at: one stray resize would otherwise stick for good.
if let screen = NSScreen.main {
    window.setFrame(screen.visibleFrame, display: false)
}
window.makeKeyAndOrderFront(nil)

let delegate = AppDelegate(window: window)
app.delegate = delegate
app.activate()
app.run()
