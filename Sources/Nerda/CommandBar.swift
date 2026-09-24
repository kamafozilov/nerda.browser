import AppKit
import SwiftUI

/// Where a new tab starts: a field on glass in the middle of the window. A tab
/// is only made once you pick somewhere to go; Esc or a click outside leaves
/// nothing behind. On the address bar (⌘L), it is the address itself, made
/// editable where it is, and takes that tab somewhere else.
struct CommandBar: View {
    /// What the field starts with, all selected, so typing replaces it.
    let text: String
    /// In the address bar, in the address's place, the list under it; or else
    /// big, in the middle of the window.
    let inline: Bool
    let go: (URL) -> Void
    let dismiss: () -> Void
    /// Counts ⌘Ts, so one with the bar already open still puts the keyboard in it.
    let requests: Int

    @State private var query = ""
    /// The row picked with the arrow keys or the pointer. Kept by what it is,
    /// not where it is, so rows arriving above it don't change what Enter does;
    /// when it goes, or none was picked, Enter takes the first row.
    @State private var highlighted: Suggestion.ID?
    /// Where the pointer last picked a row from, so only moving it does.
    @State private var pointer = NSEvent.mouseLocation
    /// Google's guesses at what is being typed, for the text they were asked for.
    @State private var searches: [String] = []
    @FocusState private var focused: Bool

    struct Suggestion: Identifiable {
        var id: String { url.absoluteString }
        let title: String
        let detail: String
        let url: URL
        /// A site shows its own icon; a search shows a magnifying glass.
        var isSearch = false
    }

    private static let maxRows = 10

    /// With nothing typed, the sites you go to most. Typing, what it means
    /// (a search, or an address), the sites and pages you've been to that
    /// match it, and Google's guesses.
    static func suggestions(for query: String, guesses searches: [String], history: History) -> [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = Address.url(from: text) else {
            return history.sites(startingWith: "").prefix(3).map(Self.suggestion)
        }

        let isSearch = url.host() == "www.google.com" && url.path() == "/search" && !text.contains("google.com")
        let typed = Suggestion(title: text, detail: isSearch ? "Search Google" : "Open", url: url, isSearch: isSearch)
        // A site of yours whose name starts with what is typed comes first,
        // for Enter to go to: "yo" is YouTube once you've been there, as in
        // Chrome. The search for it is right under. Typed out in full, it is
        // the one row.
        var rows = [typed]
        var pagesShown = 4
        if !text.contains(" "), let site = history.sites(startingWith: text).first {
            let sameSite = History.site(of: url) == History.site(of: site.url) && (url.path().isEmpty || url.path() == "/")
            rows = sameSite ? [Self.suggestion(site)] : [Self.suggestion(site), typed]
            pagesShown = 3
        }
        let lead = rows.map(\.url)
        rows += history.pages(matching: text).lazy.filter { !lead.contains($0.url) }.prefix(pagesShown).map(Self.suggestion)
        rows += searches
            .filter { $0.caseInsensitiveCompare(text) != .orderedSame }
            .compactMap { guess in Address.search(guess).map { Suggestion(title: guess, detail: "", url: $0, isSearch: true) } }
        return Array(Self.unique(rows).prefix(Self.maxRows))
    }

    private static func suggestion(_ visit: History.Visit) -> Suggestion {
        let site = History.site(of: visit.url) ?? visit.url.absoluteString
        return visit.title.isEmpty
            ? Suggestion(title: site, detail: "", url: visit.url)
            : Suggestion(title: visit.title, detail: site, url: visit.url)
    }

    /// Each address once: a page you've been to may also be what's typed, or one of Google's guesses.
    private static func unique(_ rows: [Suggestion]) -> [Suggestion] {
        var seen = Set<URL>()
        return rows.filter { seen.insert($0.url).inserted }
    }

    /// What Enter opens: the row picked, or else, once something is typed, the first.
    private func target(in rows: [Suggestion]) -> Suggestion? {
        rows.first { $0.id == highlighted } ?? (query.isEmpty ? nil : rows.first)
    }

    var body: some View {
        // Opened on an address, the list waits for it to be changed: until
        // then Enter just goes there again.
        let untouched = !text.isEmpty && query == text
        let rows = untouched ? [] : Self.suggestions(for: query, guesses: searches, history: .shared)

        Group {
            if inline {
                // In the address's own place, as the address; only the list,
                // once there is one, hangs below it over the page.
                field(rows, untouched: untouched)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .top) {
                        if !rows.isEmpty {
                            list(rows)
                                .glassPanel(cornerRadius: 12)
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(y: AddressBar.fieldHeight + 6)
                        }
                    }
                    // Clicking away (into the page) is done with it, as Esc is.
                    .onChange(of: focused) { if !focused { dismiss() } }
            } else {
                VStack(spacing: 0) {
                    field(rows, untouched: untouched)
                    if !rows.isEmpty {
                        Divider().padding(.horizontal, 12)
                    }
                    list(rows)
                }
                .frame(maxWidth: 620)
                .glassPanel(cornerRadius: 24)
            }
        }
        // A turn later: asked for in the update that adds the field, focus is
        // dropped before the field is in the window, and the keyboard (and Esc)
        // stays with the page.
        .onAppear {
            query = text
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: requests) { focused = true }
        // Typing starts the list over: the first row is what Enter will do.
        .onChange(of: query) { highlighted = nil }
        // The last guesses stay up while the next are on their way, so the
        // list doesn't flicker with every key; typing on cancels the ask.
        .task(id: query) {
            let typed = query.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty, query != text else { return searches = [] }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let found = await Address.suggestions(for: typed)
            if !Task.isCancelled { searches = found }
        }
    }

    private func field(_ rows: [Suggestion], untouched: Bool) -> some View {
        HStack(spacing: inline ? AddressBar.fieldSpacing : 12) {
            Image(systemName: "magnifyingglass")
                .font(inline ? .system(size: 12) : .title2)
                .foregroundStyle(.secondary)
                .frame(width: inline ? AddressBar.fieldIcon : nil)
            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(inline ? .system(size: 12.5) : .title2)
                .focused($focused)
                .onSubmit {
                    if let url = target(in: rows)?.url ?? (untouched ? Address.url(from: query) : nil) { go(url) }
                }
                .onKeyPress(.downArrow) {
                    let index = rows.firstIndex { $0.id == target(in: rows)?.id } ?? -1
                    if !rows.isEmpty { highlighted = rows[min(index + 1, rows.count - 1)].id }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    let index = rows.firstIndex { $0.id == target(in: rows)?.id } ?? rows.count
                    if !rows.isEmpty { highlighted = rows[max(index - 1, 0)].id }
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
        }
        .padding(.horizontal, inline ? AddressBar.fieldInset : 20)
        .frame(height: inline ? AddressBar.fieldHeight : 56)
    }

    private func list(_ rows: [Suggestion]) -> some View {
        let target = target(in: rows)
        return VStack(spacing: inline ? 1 : 2) {
            ForEach(rows) { row in
                SuggestionRow(
                    title: row.title,
                    detail: row.detail,
                    site: row.isSearch ? nil : row.url,
                    highlighted: row.id == target?.id,
                    compact: inline
                )
                // Only a pointer that moves picks a row: rows changing
                // under one at rest, as you type, leave Enter with what
                // is typed.
                .onContinuousHover { phase in
                    guard case .active = phase, NSEvent.mouseLocation != pointer else { return }
                    pointer = NSEvent.mouseLocation
                    highlighted = row.id
                }
                .onTapGesture { go(row.url) }
            }
        }
        .padding(rows.isEmpty ? 0 : inline ? 6 : 8)
    }
}

private struct SuggestionRow: View {
    let title: String
    let detail: String
    /// The site whose icon to show; nil shows a magnifying glass.
    let site: URL?
    let highlighted: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            icon.frame(width: compact ? 22 : 24, height: compact ? 22 : 24)

            Text(title)
                .font(compact ? .system(size: 13) : .title3)
                .foregroundStyle(.primary)
            Text(detail)
                .font(compact ? .system(size: 12) : .body)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // What Enter will do, on the row it will do it to.
            if highlighted {
                Image(systemName: "return")
                    .font(compact ? .system(size: 12) : .body)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, compact ? 8 : 12)
        .frame(height: compact ? 30 : 42)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 14, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let site {
            Favicon(site: site, size: compact ? 14 : 16)
        } else {
            Image(systemName: "magnifyingglass")
                .font(compact ? .system(size: 12) : .body)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// The system's glass on macOS 26 and later; its thick material before that.
    /// Tinted with the window's own ground: untinted, glass over a white page
    /// turns light, and the app's light-on-dark text on it goes unreadable.
    @ViewBuilder func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(Palette.ground.opacity(0.75)), in: shape)
        } else {
            background(.thickMaterial, in: shape)
                .overlay(shape.strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }
}
