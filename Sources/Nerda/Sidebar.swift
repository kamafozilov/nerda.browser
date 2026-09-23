import SwiftUI

/// The column down the left, on glass: the tabs, newest first, under the
/// button that opens another, and downloads in the corner. Pinned beside the
/// page, or, while collapsed, brought out over it from the window's edge.
struct Sidebar: View {
    let browser: Browser
    /// Beside the page (true), or floating over it (false).
    let pinned: Bool
    @Binding var downloadsShown: Bool
    /// Dragged wider or narrower at its right edge; see `SidebarResizer`.
    @Binding var width: Double

    static let defaultWidth: Double = 256
    static let widths: ClosedRange<Double> = 200...400
    /// As tall as the window's title bar, so the traffic lights sit in its middle.
    static let topRow: CGFloat = 52
    /// The room above and below the tabs, over which they fade as they scroll out.
    private static let edge: CGFloat = 6
    private static let listTop = "list-top"

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit on this row, and it moves the window, as
            // the title bar under it would.
            ZStack(alignment: .trailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                SidebarToggle(open: pinned, toggle: browser.toggleSidebar)
                    .padding(.trailing, 10)
            }
            .frame(height: Self.topRow)

            // Fixed: always within reach, however far down the tabs go.
            SidebarRow(icon: "plus", title: "New Tab", dimmed: true, action: browser.showCommandBar)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollViewReader { list in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(browser.tabs) { tab in
                            SidebarRow(
                                icon: "globe",
                                site: tab.site,
                                loading: tab.isLoading,
                                title: tab.title,
                                selected: tab.id == browser.selectedID,
                                close: { withAnimation(.slide) { browser.close(tab.id) } }
                            ) {
                                withAnimation(.easeOut(duration: 0.14)) { browser.selectedID = tab.id }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, Self.edge)
                    .background(alignment: .top) { Color.clear.frame(height: 0).id(Self.listTop) }
                }
                .scrollIndicators(.never)
                // Tabs fade out at the list's edges instead of being cut off
                // there, and never scroll up under New Tab.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edge)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edge)
                    }
                }
                // The tab on screen stays in sight: one opened while scrolled
                // down arrives at the top, out of view otherwise. The newest
                // brings the list right back to its top.
                .onChange(of: browser.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.slide) {
                        if id == browser.tabs.first?.id {
                            list.scrollTo(Self.listTop, anchor: .top)
                        } else {
                            list.scrollTo(id)
                        }
                    }
                }
            }

            HStack {
                DownloadsButton(browser: browser, shown: $downloadsShown)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: width)
        .background { background }
        .overlay(alignment: .trailing) { SidebarResizer(width: $width) }
    }

    /// The system's sidebar glass, pinned or floating alike, so it looks the
    /// same sliding as at rest. Floating, a shadow lifts it off the page.
    private var background: some View {
        SidebarGlass()
            .overlay(alignment: .trailing) {
                Rectangle().fill(Palette.hairline).frame(width: 1)
            }
            .shadow(color: .black.opacity(pinned ? 0 : 0.25), radius: 16, x: 4)
    }
}

/// The frosted desktop behind the window that macOS puts under sidebars
/// (Finder's, Mail's), greyed while the window is in the background as theirs
/// are. SwiftUI's own materials only blur what is in the window.
private struct SidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The sidebar's right edge: dragged, it sizes the sidebar within
/// `Sidebar.widths`; double-clicked, it puts it back to its default width.
private struct SidebarResizer: View {
    @Binding var width: Double

    /// The width the drag started from. The edge moves with the drag, so
    /// the drag is measured from where it began rather than from the edge.
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            // Half over the page, so the edge is as easy to catch from either side.
            .offset(x: 4)
            // One arrow once a limit is reached, as the system's own edges show.
            .pointerStyle(.frameResize(position: .trailing, directions: directions))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = start ?? width
                        self.start = start
                        width = min(max(start + drag.translation.width, Sidebar.widths.lowerBound), Sidebar.widths.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.slide) { width = Sidebar.defaultWidth } }
            .accessibilityHidden(true)
    }

    private var directions: FrameResizeDirection.Set {
        if width <= Sidebar.widths.lowerBound { return .outward }
        if width >= Sidebar.widths.upperBound { return .inward }
        return .all
    }
}

extension Animation {
    /// For anything that slides into place: tabs arriving and leaving, the
    /// sidebar. Without bounce: a sidebar that overshot its place would pull
    /// away from the window's edge and show a strip of the page there.
    static let slide = Animation.smooth(duration: 0.25)
}

/// One line of the sidebar: a tab, or the button that opens one.
private struct SidebarRow: View {
    let icon: String
    /// The site whose icon to show in place of `icon`.
    var site: URL?
    /// A spinner in place of the icon, once a load has taken long enough to notice.
    var loading = false
    let title: String
    var selected = false
    /// Greyed, for the New Tab button, so it reads as an action rather than a tab.
    var dimmed = false
    /// Given, the row shows a close button while the pointer is over it.
    var close: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false
    @State private var spinning = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if spinning {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity)
                    } else if let site {
                        Favicon(site: site, size: 14)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: dimmed ? .light : .regular))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 22)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(dimmed ? Palette.muted : Palette.ink)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            // Room for the close button, so a long title stops short of it.
            .padding(.trailing, close == nil ? 10 : 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background {
                shape
                    .fill(selected ? Palette.wash : hovering ? Palette.hover : .clear)
                    .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 2, y: 1)
            }
            .overlay { shape.strokeBorder(selected ? Palette.rim : .clear) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // Over the row rather than inside it, so a click on it closes the tab
        // without also selecting it.
        .overlay(alignment: .trailing) {
            if let close, hovering {
                CloseButton(action: close).padding(.trailing, 6)
            }
        }
        // After the overlay, so moving onto the close button still counts as
        // being over the row.
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        // Only loads that take a while show: a quick one would just blink.
        .task(id: loading) {
            guard loading else { return spinning = false }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { spinning = true }
        }
        .animation(.easeOut(duration: 0.15), value: spinning)
    }
}

private struct CloseButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Tab")
        .onHover { hovering = $0 }
    }
}

/// Opens and closes the sidebar (⌘S is the View menu's). One button for both
/// states: it sits at the sidebar's right edge while the sidebar is open, and
/// beside the traffic lights once it is closed.
struct SidebarToggle: View {
    let open: Bool
    let toggle: () -> Void

    @State private var hovering = false
    @State private var showsTip = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
        // The tip waits half a second under the pointer, like the system's own,
        // and goes as soon as the pointer leaves or the button is pressed.
        .task(id: hovering) {
            showsTip = false
            guard hovering else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { showsTip = true }
        }
        .onChange(of: open) { showsTip = false }
        .overlay(alignment: .topLeading) {
            if showsTip {
                Tooltip(title: title, shortcut: "⌘S")
                    .offset(y: 34)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: showsTip)
    }

    private var title: String { open ? "Collapse Tabs" : "Show Tabs" }
}

private struct Tooltip: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
            Text(shortcut)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                )
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.ground)
                .strokeBorder(Palette.hairline)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .fixedSize()
    }
}

#Preview {
    Sidebar(browser: Browser(), pinned: true, downloadsShown: .constant(false), width: .constant(Sidebar.defaultWidth))
        .frame(height: 600)
}
