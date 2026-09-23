import SwiftUI

/// The column down the left, on glass: the tabs, newest first, under the
/// button that opens another.
struct Sidebar: View {
    let browser: Browser

    static let width: CGFloat = 232
    /// As tall as the window's title bar, so the traffic lights sit in its middle.
    static let topRow: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights and the toggle, drawn over the sidebar.
            Color.clear.frame(height: Self.topRow)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(icon: "plus", title: "New Tab", dimmed: true) {
                        withAnimation(.slide) { browser.newTab() }
                    }

                    ForEach(browser.tabs) { tab in
                        SidebarRow(
                            icon: "safari",
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
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Self.width)
        .background(SidebarGlass())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
    }
}

extension Animation {
    /// For anything that slides into place: tabs arriving and leaving, the sidebar.
    static let slide = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

/// One line of the sidebar: a tab, or the button that opens one.
private struct SidebarRow: View {
    let icon: String
    let title: String
    var selected = false
    /// Greyed, for the New Tab button, so it reads as an action rather than a tab.
    var dimmed = false
    /// Given, the row shows a close button while the pointer is over it.
    var close: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: dimmed ? .light : .regular))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18)
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

/// Opens and closes the sidebar, by click or ⌘S. One button for both states:
/// it sits at the sidebar's right edge while the sidebar is open, and beside
/// the traffic lights once it is closed.
struct SidebarToggle: View {
    @Binding var open: Bool

    @State private var hovering = false
    @State private var showsTip = false

    var body: some View {
        Button {
            withAnimation(.slide) { open.toggle() }
        } label: {
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
        .keyboardShortcut("s", modifiers: .command)
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

/// The system's own sidebar material: the desktop shows through, blurred,
/// and it turns flat when the window is not in front, like Finder's.
private struct SidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

#Preview {
    Sidebar(browser: Browser()).frame(height: 600)
}
