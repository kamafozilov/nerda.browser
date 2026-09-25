import SwiftUI

/// Every page visited (⌘Y), in a tab of its own, as Chrome's and Safari's
/// history: latest first, under the day each was last seen, with a field
/// that looks through titles and addresses. A page opens in a tab of its own
/// (⌘-click, behind this one), so the list stays; each can be taken out.
struct HistoryPage: View {
    let browser: Browser

    @State private var query = ""
    /// Worked out as the page opens, as what is typed changes, and as pages
    /// come or go: not as the page is drawn, which a tab naming its page
    /// anywhere asked for again, sorting thousands of pages each time.
    @State private var lines: [Line] = []
    @State private var hasPages = false
    /// The list Delete browsing data's Period opened.
    @State private var dropdown: Dropdown?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("History")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button("Clear History…", action: browser.clearHistory)
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(!hasPages)
                }
                .padding(.leading, 12)
                SettingsSearch(query: $query, prompt: "Search History") {}
                    .padding(.top, 18)
                if lines.isEmpty {
                    Text(query.isEmpty ? "No pages visited yet" : "No pages match")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, 12)
                        .padding(.top, 24)
                }
                // One line at a time, so only those in view are made: a day's
                // pages are each a line of the lazy stack, and together they
                // make up the day's rounded box.
                ForEach(lines) { line in
                    switch line {
                    case .day(let day):
                        Text(Self.heading(for: day))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.leading, 12)
                            .padding(.top, 26)
                            .padding(.bottom, 8)
                    case .page(let visit, let first, let last):
                        HistoryRow(visit: visit) { inBackground in
                            withAnimation(.slide) { browser.open(visit.url, inBackground: inBackground) }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, first ? 4 : 0)
                        .padding(.bottom, last ? 4 : 0)
                        .background(Color.primary.opacity(0.045), in: UnevenRoundedRectangle(
                            topLeadingRadius: first ? 10 : 0, bottomLeadingRadius: last ? 10 : 0,
                            bottomTrailingRadius: last ? 10 : 0, topTrailingRadius: first ? 10 : 0, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
            .dialogBlur(browser.clearingHistory)
        }
        .scrollIndicators(.never)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .overlay {
            if browser.clearingHistory {
                DeleteDataDialog(browser: browser, escapes: dropdown == nil) { browser.clearingHistory = false }
            }
        }
        .padding(.top, 2)
        .dropdownHost($dropdown)
        .background { PagesComeAndGo(changed: refresh) }
        .onAppear(perform: refresh)
        // Not left to come up again over the next history page.
        .onDisappear { browser.clearingHistory = false }
        .onChange(of: query, refresh)
    }

    private func refresh() {
        lines = Self.lines(of: Self.days(of: History.shared.visits.values, matching: query))
        hasPages = !History.shared.visits.isEmpty
    }

    /// A line of the page: a day's heading, or one of its pages, first or
    /// last of the day's box, or both.
    enum Line: Identifiable {
        case day(Date)
        case page(History.Visit, first: Bool, last: Bool)

        var id: String {
            switch self {
            case .day(let day): "day \(day.timeIntervalSinceReferenceDate)"
            case .page(let visit, _, _): visit.url.absoluteString
            }
        }
    }

    static func lines(of days: [(day: Date, visits: [History.Visit])]) -> [Line] {
        days.flatMap { day in
            [Line.day(day.day)] + day.visits.indices.map { index in
                .page(day.visits[index], first: index == 0, last: index == day.visits.count - 1)
            }
        }
    }

    /// The visits whose title or address has what is typed in it, latest
    /// first, by the day of their last visit.
    static func days(of visits: some Sequence<History.Visit>, matching query: String,
                     calendar: Calendar = .current) -> [(day: Date, visits: [History.Visit])] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let found = visits
            .filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(text) }
            .sorted { $0.last > $1.last }
        var days: [(day: Date, visits: [History.Visit])] = []
        for visit in found {
            let day = calendar.startOfDay(for: visit.last)
            if days.last?.day == day { days[days.count - 1].visits.append(visit) } else { days.append((day, [visit])) }
        }
        return days
    }

    private static func heading(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// Tells the page when pages are added to history or taken out. A view of its
/// own, so that only it, not the page's list, is looked at again whenever
/// history changes.
private struct PagesComeAndGo: View {
    let changed: () -> Void

    var body: some View {
        Color.clear.onChange(of: History.shared.visits.count, changed)
    }
}

/// One page: when, its icon, title and site. A click opens it; the pointer
/// over it brings out the button that takes it out of history.
private struct HistoryRow: View {
    let visit: History.Visit
    /// In a tab of its own, in front or (⌘-click) behind.
    let open: (_ inBackground: Bool) -> Void

    @State private var hovering = false

    var body: some View {
        let site = History.site(of: visit.url) ?? visit.url.absoluteString
        Button { open(NSEvent.modifierFlags.contains(.command)) } label: {
            HStack(spacing: 12) {
                Text(visit.last.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .frame(width: 64, alignment: .leading)
                Favicon(site: visit.url, size: 14, plate: false)
                    .frame(width: 18)
                Text(visit.title.isEmpty ? site : visit.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if !visit.title.isEmpty {
                    Text(site)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            // Room for the button that takes it out.
            .padding(.trailing, 36)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visit.url.absoluteString)
        .overlay(alignment: .trailing) {
            if hovering {
                Button { withAnimation(.snappy(duration: 0.2)) { History.shared.remove(visit.url) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from History")
                .accessibilityLabel("Remove from History")
                .padding(.trailing, 8)
            }
        }
        .onHover { hovering = $0 }
    }
}
