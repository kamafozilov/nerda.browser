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

    private struct Suggestion: Identifiable {
        var id: String { url.absoluteString }
        let title: String
        let detail: String
        let url: URL
        /// A site shows its own icon; a search shows a magnifying glass.
        var isSearch = false
    }

    // ponytail: a fixed list until there is history to suggest from.
    private static let topSites: [Suggestion] = [
        ("YouTube", "youtube.com"),
        ("Wikipedia", "wikipedia.org"),
        ("GitHub", "github.com"),
    ].map { Suggestion(title: $0.0, detail: $0.1, url: URL(string: "https://\($0.1)")!) }

    private var suggestions: [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = Address.url(from: text) else { return Self.topSites }

        let isSearch = url.host() == "www.google.com" && url.path() == "/search" && !text.contains("google.com")
        let first = Suggestion(title: text, detail: isSearch ? "Search Google" : "Open", url: url, isSearch: isSearch)
        let matches = Self.topSites.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.detail.localizedCaseInsensitiveContains(text)
        }
        let guesses = searches
            .filter { $0.caseInsensitiveCompare(text) != .orderedSame }
            .prefix(6)
            .compactMap { guess in Address.search(guess).map { Suggestion(title: guess, detail: "", url: $0, isSearch: true) } }
        return [first] + matches.filter { $0.url != url } + guesses
    }

    /// What Enter opens: the row picked, or else, once something is typed, the first.
    private func target(in rows: [Suggestion]) -> Suggestion? {
        rows.first { $0.id == highlighted } ?? (query.isEmpty ? nil : rows.first)
    }

    var body: some View {
        let rows = suggestions

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
