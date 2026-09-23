import SwiftUI

/// The column down the left, on glass. Empty for now.
struct Sidebar: View {
    static let width: CGFloat = 232
    /// As tall as the window's title bar, so the traffic lights sit in its middle.
    static let topRow: CGFloat = 52

    var body: some View {
        SidebarGlass()
            .frame(width: Self.width)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Palette.hairline).frame(width: 1)
            }
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
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { open.toggle() }
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
    Sidebar().frame(height: 600)
}
