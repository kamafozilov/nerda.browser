import AppKit
import SwiftUI

/// Where a new tab starts: a field on glass in the middle of the window. A tab
/// is only made once you pick somewhere to go; Esc or a click outside leaves
/// nothing behind.
struct CommandBar: View {
    let go: (URL) -> Void
    let dismiss: () -> Void

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
        let rows = Self.suggestions(for: query, guesses: searches, history: .shared)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { if let row = target(in: rows) { go(row.url) } }
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
            .padding(.horizontal, 20)
            .frame(height: 56)

            Divider().padding(.horizontal, 12)

            let target = target(in: rows)
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    SuggestionRow(
                        title: row.title,
                        detail: row.detail,
                        site: row.isSearch ? nil : row.url,
                        highlighted: row.id == target?.id
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
            .padding(8)
        }
        .frame(width: 620)
        .glassPanel(cornerRadius: 24)
        .onAppear { focused = true }
        // Typing starts the list over: the first row is what Enter will do.
        .onChange(of: query) { highlighted = nil }
        // The last guesses stay up while the next are on their way, so the
        // list doesn't flicker with every key; typing on cancels the ask.
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return searches = [] }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let found = await Address.suggestions(for: text)
            if !Task.isCancelled { searches = found }
        }
    }
}

private struct SuggestionRow: View {
    let title: String
    let detail: String
    /// The site whose icon to show; nil shows a magnifying glass.
    let site: URL?
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 24, height: 24)

            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // What Enter will do, on the row it will do it to.
            if highlighted {
                Image(systemName: "return")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let site {
            Favicon(site: site)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.body)
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
