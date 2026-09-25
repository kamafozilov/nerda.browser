import AppKit
import SwiftUI

/// Where to go, in one of three places (`Place`).
struct CommandBar: View {
    enum Place {
        /// The address bar's address, made editable where it is (⌘L), to take
        /// that tab somewhere else; only the list hangs below it, over the page.
        case address
        /// The tab switcher (⌘⇧A), on glass in the middle of the window: the
        /// open tabs first, then anywhere else, in a tab of its own. Esc or a
        /// click outside leaves nothing behind.
        case switcher
        /// A new tab's own field, on clear glass over its picture, alone until
        /// something is typed.
        case newTab
    }

    /// What the field starts with, all selected, so typing replaces it.
    let text: String
    let place: Place
    let go: (URL) -> Void
    let dismiss: () -> Void
    /// Counts asks for it, so one with the bar already open still puts the keyboard in it.
    let requests: Int
    /// Open tabs to offer, as the switcher, and what picking one does.
    var tabs: [Tab] = []
    var select: (Tab.ID) -> Void = { _ in }
    /// The pages to suggest from (`Browser.history`).
    var history = History.shared

    @State private var query = ""
    /// The row picked with the arrow keys or the pointer. Kept by what it is,
    /// not where it is, so rows arriving above it don't change what Enter does;
    /// when it goes, or none was picked, Enter takes the first row.
    @State private var highlighted: Suggestion.ID?
    /// Where the pointer last picked a row from, so only moving it does.
    @State private var pointer = NSEvent.mouseLocation
    /// The search engine's guesses at what is being typed, for the text they were asked for.
    @State private var searches: [String] = []
    @FocusState private var focused: Bool
    /// Where the address's field and its list are, in the window, for a
    /// click anywhere else to put them away.
    @State private var frames: [CGRect] = [.zero, .zero]
    @State private var clicks: Any?
    @Environment(\.incognito) private var incognito

    private var inline: Bool { place == .address }

    struct Suggestion: Identifiable {
        var id: String { tab?.uuidString ?? url.absoluteString }
        let title: String
        let detail: String
        let url: URL
        /// A site shows its own icon; a search shows a magnifying glass.
        var isSearch = false
        /// An open tab, to go to rather than open `url` again.
        var tab: Tab.ID?
    }

    private static let maxRows = 10

    /// First the open tabs whose title or site has what is typed in it, the
    /// ones seen last first. Then, with nothing typed, the sites you went to
    /// last, latest first. Typing, what it means (a search, or an address), the sites and
    /// pages you've been to that match it, and the search engine's guesses.
    static func suggestions(for query: String, guesses searches: [String], history: History,
                            tabs: [Tab] = []) -> [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let open = tabs
            .filter { tab in
                guard let site = tab.site else { return false }
                return text.isEmpty || tab.title.localizedCaseInsensitiveContains(text)
                    || History.site(of: site)?.localizedCaseInsensitiveContains(text) == true
            }
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { Suggestion(title: $0.title, detail: "Switch to Tab", url: $0.site!, tab: $0.id) }
        guard !text.isEmpty, let url = Address.url(from: text) else {
            return Array(Self.unique(open + history.recentSites(6).map(Self.suggestion))
                .prefix(Self.maxRows))
        }

        let isSearch = url == Address.search(text)
        let typed = Suggestion(title: text, detail: isSearch ? "Search \(SearchEngine.current.name)" : "Open",
                               url: url, isSearch: isSearch)
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
        rows += history.pages(matching: text, limit: pagesShown + lead.count)
            .filter { !lead.contains($0.url) }.prefix(pagesShown).map(Self.suggestion)
        rows += searches
            .filter { $0.caseInsensitiveCompare(text) != .orderedSame }
            .compactMap { guess in Address.search(guess).map { Suggestion(title: guess, detail: "", url: $0, isSearch: true) } }
        return Array(Self.unique(open.prefix(4) + rows).prefix(Self.maxRows))
    }

    private static func suggestion(_ visit: History.Visit) -> Suggestion {
        let site = History.site(of: visit.url) ?? visit.url.absoluteString
        return visit.title.isEmpty
            ? Suggestion(title: site, detail: "", url: visit.url)
            : Suggestion(title: visit.title, detail: site, url: visit.url)
    }

    /// Each address once: a page you've been to may also be what's typed, or one of the search engine's guesses.
    /// Open tabs all stay, two on the same address included, and hide the rest's rows for it.
    private static func unique(_ rows: [Suggestion]) -> [Suggestion] {
        var seen = Set<URL>()
        return rows.filter { seen.insert($0.url).inserted || $0.tab != nil }
    }

    /// What Enter opens: the row picked, or else, once something is typed, the
    /// first; with nothing typed, the tab seen last, to go back to.
    private func target(in rows: [Suggestion]) -> Suggestion? {
        rows.first { $0.id == highlighted } ?? (query.isEmpty && rows.first?.tab == nil ? nil : rows.first)
    }

    private func open(_ row: Suggestion) {
        if let tab = row.tab { select(tab) } else { go(row.url) }
    }

    var body: some View {
        // Opened on an address, the list waits for it to be changed: until
        // then Enter just goes there again.
        let untouched = !text.isEmpty && query == text
        let blank = place == .newTab && query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = untouched || blank ? [] : Self.suggestions(for: query, guesses: searches, history: history, tabs: tabs)

        Group {
            if inline {
                // In the address's own place, as the address; only the list,
                // once there is one, hangs below it over the page.
                field(rows, untouched: untouched)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[0] = $0 }
                    .overlay(alignment: .top) {
                        if !rows.isEmpty {
                            list(rows)
                                .glassPanel(cornerRadius: 12)
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(y: AddressBar.fieldHeight + 6)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[1] = $0 }
                                .onDisappear { frames[1] = .zero }
                        }
                    }
                    // Clicking away is done with it, as Esc is: into the page,
                    // which takes the keyboard, or anywhere else, which doesn't
                    // (a new tab's picture, the sidebar).
                    .onChange(of: focused) { if !focused { dismiss() } }
                    .onAppear { clicks = watchClicksAway() }
                    .onDisappear { clicks.map(NSEvent.removeMonitor) }
            } else {
                VStack(spacing: 0) {
                    field(rows, untouched: untouched)
                    if !rows.isEmpty {
                        Divider().padding(.horizontal, 12)
                    }
                    list(rows)
                }
                .frame(maxWidth: 620)
                // An incognito new tab's has no picture to sit on: lighter
                // than the plain dark page, so it stands out from it.
                .background(place == .newTab && incognito ? Palette.incognitoField : .clear,
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                // The switcher's glass; a new tab's is a capsule while it is
                // the field alone, on its own picture rather than a page.
                .glassPanel(cornerRadius: place == .newTab ? 26 : 24, lifted: place != .newTab)
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
        // Where Enter would go is connected to while the rest is typed.
        .onChange(of: target(in: rows).flatMap { $0.tab == nil ? $0.url : nil }) { _, url in
            if let url { Tab.preconnect(to: url) }
        }
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

    /// Clicks outside the field and its list put them away, and still do
    /// what they were for.
    private func watchClicksAway() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard let view = event.window?.contentView else { return event }
            // SwiftUI's window space runs down from the top.
            let point = CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y)
            if !frames.contains(where: { $0.contains(point) }) { dismiss() }
            return event
        }
    }

    private func field(_ rows: [Suggestion], untouched: Bool) -> some View {
        HStack(spacing: inline ? AddressBar.fieldSpacing : 12) {
            Image(systemName: "magnifyingglass")
                .font(inline ? .system(size: 12) : place == .newTab ? .title3 : .title2)
                .foregroundStyle(.secondary)
                .frame(width: inline ? AddressBar.fieldIcon : nil)
            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(inline ? .system(size: 12.5) : place == .newTab ? .title3 : .title2)
                .focused($focused)
                .onSubmit {
                    if let row = target(in: rows) {
                        open(row)
                    } else if untouched, let url = Address.url(from: query) {
                        go(url)
                    }
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
        .frame(height: inline ? AddressBar.fieldHeight : place == .newTab ? 52 : 56)
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
                .onTapGesture { open(row) }
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
    /// Over a page, a fine edge and a shadow keep it off a page of its own
    /// colour (dark glass on a black site, light on a white one).
    @ViewBuilder func glassPanel(cornerRadius: CGFloat, tint: Double = 0.75, lifted: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(Palette.ground.opacity(tint)), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(lifted ? 0.14 : 0)))
                .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 24, y: 10)
        } else {
            background(.thickMaterial, in: shape)
                .overlay(shape.strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }
}
