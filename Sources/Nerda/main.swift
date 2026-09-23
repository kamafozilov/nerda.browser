import AppKit
import SwiftUI

/// The whole window: the sidebar, and the page beside it.
struct BrowserView: View {
    @State private var browser = Browser()
    @State private var sidebarOpen = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarOpen {
                Sidebar(browser: browser).transition(.move(edge: .leading))
            }
            ZStack {
                Palette.ground
                // The page goes here; for now just the tab's name. Keyed by the
                // tab, so each one gets its own view, as each will get its own page.
                if let tab = browser.selected {
                    Text(tab.title)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.muted)
                        .id(tab.id)
                        .transition(.opacity)
                }
            }
        }
        // ⌘T and ⌘W, here rather than on a view in the sidebar so they still
        // work while the sidebar is closed.
        .background {
            Group {
                Button("New Tab") { withAnimation(.slide) { browser.newTab() } }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") {
                    guard let id = browser.selectedID else { return }
                    withAnimation(.slide) { browser.close(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            .hidden()
        }
        // The title bar is under the top row, so the window is dragged from there.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: Sidebar.topRow)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .overlay(alignment: .topLeading) {
            SidebarToggle(open: $sidebarOpen)
                // Open: at the sidebar's right edge. Closed: past the traffic
                // lights, which end at 79pt.
                .padding(.leading, sidebarOpen ? Sidebar.width - 10 - 28 : 86)
                .frame(height: Sidebar.topRow)
        }
        .ignoresSafeArea()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

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
window.contentView = NSHostingView(rootView: BrowserView())
window.center()
window.makeKeyAndOrderFront(nil)

app.activate()
app.run()
