import SwiftUI

/// Where a new tab starts: a field on glass in the middle of the window. A tab
/// is only made once you pick somewhere to go; Esc or a click outside leaves
/// nothing behind.
struct CommandBar: View {
    let go: (URL) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted: Int?
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
        ("Google", "google.com"),
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
        return [first] + matches.filter { $0.url != url }
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
                    .onSubmit { open(highlighted ?? (query.isEmpty ? nil : 0), in: rows) }
                    .onKeyPress(.downArrow) {
                        highlighted = min((highlighted ?? -1) + 1, rows.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max((highlighted ?? rows.count) - 1, 0)
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

            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SuggestionRow(
                        title: row.title,
                        detail: row.detail,
                        site: row.isSearch ? nil : row.url,
                        highlighted: index == highlighted
                    )
                    .onHover { if $0 { highlighted = index } }
                    .onTapGesture { open(index, in: rows) }
                }
            }
            .padding(8)
        }
        .frame(width: 620)
        .glassPanel(cornerRadius: 24)
        .onAppear { focused = true }
        // Typing starts the list over: the first row is what Enter will do.
        .onChange(of: query) { highlighted = query.isEmpty ? nil : 0 }
    }

    private func open(_ index: Int?, in rows: [Suggestion]) {
        guard let index, rows.indices.contains(index) else { return }
        go(rows[index].url)
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
