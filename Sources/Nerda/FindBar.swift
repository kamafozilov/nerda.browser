import SwiftUI

/// Find in page, in the page's top corner: Return for the next match, ⇧Return
/// for the one before, Esc to put it away. Match Case and Whole Words are in
/// the magnifying glass's menu, as in Safari.
struct FindBar: View {
    @Bindable var browser: Browser

    @FocusState private var focused: Bool
    @AppStorage(Browser.findMatchCaseKey) private var matchCase = false
    @AppStorage(Browser.findWholeWordsKey) private var wholeWords = false

    var body: some View {
        HStack(spacing: 8) {
            FindOptions(matchCase: $matchCase, wholeWords: $wholeWords)
            TextField("Find on Page", text: $browser.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { browser.find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) {
                    browser.hideFindBar()
                    return .handled
                }
            if let matches = browser.findMatches {
                // As Safari counts: 1000 at most, then "1000+".
                Text(matches.count == 0 ? "No results" : "\(matches.index) of \(matches.count)\(matches.more ? "+" : "")")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Divider().frame(height: 16)
            FindButton(symbol: "chevron.up", label: "Previous Match") { browser.find(backwards: true) }
            FindButton(symbol: "chevron.down", label: "Next Match") { browser.find() }
            FindButton(symbol: "xmark", label: "Done", action: browser.hideFindBar)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(width: 360, height: 36)
        .glassPanel(cornerRadius: 18)
        // A turn later, as the command bar does: focus asked for as the field
        // is added is dropped. The last query, opened again, is lit again.
        .onAppear {
            DispatchQueue.main.async { focused = true }
            if !browser.findQuery.isEmpty { browser.findTyped() }
        }
        // Looks as you type, from the top, as Safari does.
        .onChange(of: browser.findQuery) { browser.findTyped() }
        .onChange(of: matchCase) { browser.findTyped() }
        .onChange(of: wholeWords) { browser.findTyped() }
        // The count was the last tab's: Return looks in this one.
        .onChange(of: browser.selectedID) { browser.clearFound() }
        // ⌘F with the bar already open goes back to its field.
        .onChange(of: browser.findRequests) { focused = true }
    }
}

/// The magnifying glass, with its chevron, as Safari's: a menu of how to match.
private struct FindOptions: View {
    @Binding var matchCase: Bool
    @Binding var wholeWords: Bool

    @State private var hovering = false

    var body: some View {
        Menu {
            Toggle("Match Case", isOn: $matchCase)
            Toggle("Whole Words", isOn: $wholeWords)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "magnifyingglass")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .frame(width: 30, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Find Options")
        .accessibilityLabel("Find Options")
        .onHover { hovering = $0 }
    }
}

private struct FindButton: View {
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
