import SwiftUI
import WebKit

/// What Nerda keeps of where you have been, and what it lets pages load.
struct PrivacySettings: View {
    let browser: Browser
    let deleteData: () -> Void

    @Bindable private var blocker = Blocker.shared
    @AppStorage(HistoryKeep.key) private var keep = HistoryKeep.threeMonths
    @AppStorage(IncognitoAutoLock.key) private var lock = IncognitoAutoLock.minute
    @AppStorage(HTTPSUpgrade.key) private var upgradesToHTTPS = true

    var body: some View {
        SettingsGroup(title: "Browsing history") {
            SettingsRow(title: "Delete browsing history", detail: "Delete history, cookies, cache, and more", icon: "trash") {
                Button("Delete", role: .destructive, action: deleteData)
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
            SettingsRow(title: "Keep history for", detail: "Pages you visited longer ago are removed", icon: "calendar.badge.clock") {
                DropdownButton(label: keep.name,
                               options: HistoryKeep.allCases.map { DropdownOption(id: "\($0.rawValue)", title: $0.name) },
                               selected: "\(keep.rawValue)") { keep = Int($0).flatMap(HistoryKeep.init) ?? .threeMonths }
            }
            SettingsLink(title: "View browsing history", icon: "clock.arrow.circlepath", action: browser.openHistory)
        }
        .onChange(of: keep) {
            // Each profile's with a window; another's as it is next written.
            for window in NSApp.windows { (window as? BrowserWindow)?.browser.history.keepChanged() }
        }
        SettingsGroup(title: "Adblock") {
            SettingsRow(title: "Block ads and trackers", detail: blockDetail, icon: "hand.raised") {
                SettingsToggle(title: "Block ads and trackers", isOn: $blocker.isEnabled)
            }
            SettingsRow(title: "Manage filters", detail: blocker.chosen.count == 1 ? "1 filter on" : "\(blocker.chosen.count) filters on",
                        icon: "slider.horizontal.3") {
                FiltersButton()
            }
        }
        SettingsGroup(title: "Security") {
            SettingsRow(title: "Upgrade connections to HTTPS",
                        detail: "Open http:// sites over HTTPS when they support it, and over HTTP when they don't",
                        icon: "lock") {
                SettingsToggle(title: "Upgrade connections to HTTPS", isOn: $upgradesToHTTPS)
            }
        }
        SettingsGroup(title: "Incognito") {
            SettingsRow(title: "Lock incognito windows",
                        detail: "After Nerda is in the background this long, and whenever your Mac locks or sleeps",
                        icon: "lock.rectangle.stack") {
                DropdownButton(label: lock.name,
                               options: IncognitoAutoLock.allCases.map {
                                   DropdownOption(id: "\($0.rawValue)", title: $0.name, separated: $0 == .quarterHour)
                               },
                               selected: "\(lock.rawValue)") { lock = Int($0).flatMap(IncognitoAutoLock.init) ?? .minute }
            }
        }
    }

    private var blockDetail: String {
        if blocker.refreshing { return "Updating filters…" }
        if blocker.failed { return "Some filters couldn't be updated. Nerda tries again later" }
        guard let updated = blocker.updated else { return "If a site has trouble, turn this off and reload it" }
        return "Last updated \(updated.formatted(.relative(presentation: .named)))"
    }
}

/// How far back Delete browsing data goes: Chrome's choices, all time first.
enum DeleteRange: String, CaseIterable {
    case all, quarterHour, hour, day, week, month

    var name: String {
        switch self {
        case .all: "All time"
        case .quarterHour: "Last 15 minutes"
        case .hour: "Last hour"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 4 weeks"
        }
    }

    /// The first moment deleted.
    var since: Date {
        let minutes: Double = switch self {
        case .all: 0
        case .quarterHour: 15
        case .hour: 60
        case .day: 24 * 60
        case .week: 7 * 24 * 60
        case .month: 28 * 24 * 60
        }
        return self == .all ? .distantPast : .now.addingTimeInterval(-minutes * 60)
    }
}

/// What to delete, and from how far back, as Chrome and Aside ask it. Only
/// what is safe to lose comes ticked, every time: cookies and site storage
/// hold your sign-ins, so they go only when ticked on purpose. Passwords are
/// Nerda's own, in the keychain, and never go this way.
struct DeleteDataDialog: View {
    let browser: Browser
    let escapes: Bool
    let done: () -> Void

    @State private var range = DeleteRange.all
    @State private var history = true
    @State private var cache = true
    @State private var downloads = true
    @State private var cookies = false
    @State private var storage = false
    /// How many sites keep cookies, to say who you are signed out of.
    @State private var sites: Int?
    @State private var deleting = false

    private static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache,
    ]
    private static let cookieTypes: Set<String> = [WKWebsiteDataTypeCookies]
    /// Local storage, IndexedDB, service workers and the rest sites keep.
    private static let storageTypes = WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes).subtracting(cookieTypes)

    var body: some View {
        let since = range.since
        let pages = browser.history.visits.values.count { $0.last >= since }
        SettingsDialog(width: 380, escapes: escapes, cancel: done) {
            Text("Delete browsing data")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Deletes what you choose from this Mac. Open tabs and saved passwords stay.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            label("Period")
                .padding(.top, 18)
            DropdownButton(label: range.name,
                           options: DeleteRange.allCases.map {
                               DropdownOption(id: $0.rawValue, title: $0.name, separated: $0 == .all)
                           },
                           selected: range.rawValue, fill: true) { range = DeleteRange(rawValue: $0) ?? .all }
            label("Items to delete")
                .padding(.top, 18)
            VStack(alignment: .leading, spacing: 10) {
                item("Browsing history", pages == 0 ? "No pages visited in this period"
                     : "\(pages == 1 ? "1 page" : "\(pages) pages") visited in this period, and their suggestions as you type",
                     isOn: $history)
                item("Cached images and files", "Kept to load sites faster. Sites may load more slowly the next time you visit",
                     isOn: $cache)
                item("Download history", "The list in Downloads. The files themselves stay", isOn: $downloads)
                item("Cookies", (range == .all && sites != nil ? "From \(sites == 1 ? "1 site" : "\(sites!) sites"). " : "")
                     + "Signs you out of most sites", isOn: $cookies)
                item("Site storage", "What sites save on this Mac, such as drafts and offline data. May sign you out of some sites",
                     isOn: $storage)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(SettingsButtonStyle())
                Button(deleting ? "Deleting…" : "Delete", role: .destructive) { Task { await delete(since: since) } }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(deleting || !(history || cache || downloads || cookies || storage))
            }
            .padding(.top, 22)
        }
        .task { sites = await browser.dataStore.dataRecords(ofTypes: Self.cookieTypes).count }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.bottom, 8)
    }

    /// A choice, with what it deletes behind the ⓘ.
    private func item(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Toggle(title, isOn: isOn)
                .toggleStyle(SettingsCheckbox())
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .help(detail)
                .accessibilityLabel(detail)
        }
    }

    private func delete(since: Date) async {
        deleting = true
        // The profile's windows only, an incognito one's downloads included:
        // another profile's are none of this one's browsing.
        let windows = NSApp.windows.compactMap { ($0 as? BrowserWindow)?.browser }.filter { $0.profile === browser.profile }
        if history {
            browser.history.remove(since: since)
            for window in windows {
                window.recentlyClosed.removeAll { $0.date >= since }
                window.sessionChanged()
            }
        }
        if downloads {
            for window in windows { window.clearDownloads(since: since) }
        }
        let types = (cache ? Self.cacheTypes : []).union(cookies ? Self.cookieTypes : []).union(storage ? Self.storageTypes : [])
        if !types.isEmpty { await browser.dataStore.removeData(ofTypes: types, modifiedSince: since) }
        done()
    }
}

/// Configure, by Manage filters: the filter lists, opened under it.
private struct FiltersButton: View {
    @Environment(\.dropdown) private var dropdown
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            dropdown.wrappedValue = Dropdown(anchor: frame, below: true, options: [], selected: nil, choose: { _ in },
                                             panel: (AnyView(FiltersPanel()), CGSize(width: 330, height: 440)))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Configure")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Dropdown.space)) } action: { frame = $0 }
    }
}

/// The filter lists to block with, by heading, each ticked on or off where it
/// is (the panel stays), found by name; and lists of one's own, by address.
private struct FiltersPanel: View {
    @State private var query = ""
    @State private var adding = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    private let blocker = Blocker.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                TextField("Search filters", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.heading) { section in
                        Text(section.heading)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 9)
                            .padding(.top, section.heading == sections.first?.heading ? 2 : 12)
                            .padding(.bottom, 4)
                        ForEach(section.lists) { list in
                            FilterRow(list: list, chosen: blocker.isChosen(list),
                                      remove: section.heading == Self.added ? { blocker.remove(list) } : nil) {
                                blocker.toggle(list)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("No filters found")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .padding(9)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            footer
                .font(.system(size: 13.5))
                .padding(.horizontal, 14)
                .frame(height: 44)
        }
    }

    private static let added = "Added"

    /// The catalogue, lists of one's own first, under what is typed.
    private var sections: [(heading: String, lists: [FilterList])] {
        let all = (blocker.added.isEmpty ? [] : [(Self.added, blocker.added)]) + FilterList.catalog
        let typed = query.trimmingCharacters(in: .whitespaces)
        return all.map { ($0.0, typed.isEmpty ? $0.1 : $0.1.filter { $0.title.localizedCaseInsensitiveContains(typed) }) }
            .filter { !$0.1.isEmpty }
    }

    @ViewBuilder private var footer: some View {
        if adding {
            HStack(spacing: 8) {
                TextField("Address of a filter list", text: $address)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit(add)
                    .onAppear { addressFocused = true }
                Button("Add", action: add)
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(url == nil)
            }
        } else {
            HStack {
                Button { adding = true } label: {
                    Label("Add filter", systemImage: "plus")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
                Spacer()
                Button(action: blocker.update) {
                    Label(blocker.refreshing ? "Updating…" : "Update now", systemImage: "arrow.clockwise")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .disabled(blocker.refreshing)
            }
        }
    }

    /// What is typed, if it is a web address.
    private var url: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme), url.host() != nil else { return nil }
        return url
    }

    private func add() {
        guard let url else { return }
        blocker.add(url)
        address = ""
        adding = false
    }
}

/// One list: ticked when it is blocked with. One's own can be taken off.
private struct FilterRow: View {
    let list: FilterList
    let chosen: Bool
    let remove: (() -> Void)?
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(list.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                if let remove, hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(list.url.absoluteString)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
