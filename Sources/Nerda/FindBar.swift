import SwiftUI

/// Find in page, in the page's top corner: Return for the next match, ⇧Return
/// for the one before, Esc to put it away.
struct FindBar: View {
    @Bindable var browser: Browser

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find on Page", text: $browser.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { browser.find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) {
                    browser.hideFindBar()
                    return .handled
                }
            if browser.findMissing {
                Text("Not found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Divider().frame(height: 16)
            BarButton(symbol: "chevron.up", label: "Previous Match") { browser.find(backwards: true) }
            BarButton(symbol: "chevron.down", label: "Next Match") { browser.find() }
            BarButton(symbol: "xmark", label: "Done", action: browser.hideFindBar)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: 320, height: 36)
        .glassPanel(cornerRadius: 18)
        .onAppear { focused = true }
        // Looks as you type, from the top, as Safari does.
        .onChange(of: browser.findQuery) { browser.find() }
        // ⌘F with the bar already open goes back to its field.
        .onChange(of: browser.findRequests) { focused = true }
    }
}

private struct BarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}
