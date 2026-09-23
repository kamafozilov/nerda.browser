import AppKit
import SwiftUI

/// The whole window: the sidebar, and the page beside it.
struct BrowserView: View {
    @State private var sidebarOpen = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarOpen {
                Sidebar().transition(.move(edge: .leading))
            }
            Palette.ground  // the page goes here
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
