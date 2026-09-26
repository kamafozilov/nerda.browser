import SwiftUI
import WebKit

/// The pages of Nerda's settings, listed down the settings tab's left. Only
/// what works is listed: a page comes once it has something in it.
enum SettingsPage: String, CaseIterable, Identifiable, Codable {
    case general, appearance, privacy, extensions, shortcuts, releaseNotes

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .privacy: "Security & Privacy"
        case .extensions: "Extensions"
        case .shortcuts: "Keyboard Shortcuts"
        case .releaseNotes: "Release Notes"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .privacy: "lock"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "keyboard"
        case .releaseNotes: "sparkles"
        }
    }

    /// The heading it is listed under.
    var section: String {
        switch self {
        case .general, .appearance, .privacy, .extensions, .shortcuts: "Personal"
        case .releaseNotes: "Nerda"
        }
    }

    /// What the page holds, so a search finds it by a setting as well as by its name.
    private var keywords: [String] {
        switch self {
        case .general: ["default browser", "search engine", "google", "picture in picture", "video", "screenshot", "language", "spell", "quit", "warn", "about", "version", "updates"]
        case .appearance: ["theme", "dark", "light", "zoom", "tab style", "vertical", "horizontal", "sidebar", "transparency", "tinted", "transparent", "glass"]
        case .privacy: ["security", "history", "delete", "clear", "cookies", "cache", "site data", "ads", "trackers", "adblock", "blocking", "filters", "easylist", "ublock", "adguard"]
        case .extensions: ["chrome web store", "add-ons", "plugins", "unpacked", "developer"] + Extensions.shared.installed.map(\.name)
        case .shortcuts: ["keyboard", "keys", "hotkeys"] + ShortcutsSettings.groups.flatMap { $0.shortcuts.map(\.title) }
        case .releaseNotes: ["what's new", "changelog", "changes", "version", "updates"]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || ([title] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// A page saved by a version that had more of them opens on General.
    init(from decoder: any Decoder) throws {
        self = SettingsPage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .general
    }
}

/// The settings tab: its pages down the left, under a field that searches
/// them, and the one open on a card beside them.
struct SettingsView: View {
    let browser: Browser
    let tab: Tab

    @State private var query = ""
    /// The list a dropdown button opened, over everything else.
    @State private var dropdown: Dropdown?
    @State private var editingLanguages = false
    @State private var deletingData = false
    @State private var languages = PreferredLanguage.chosen

    var body: some View {
        let open = tab.settings ?? .general
        let found = SettingsPage.allCases.filter { $0.matches(query) }
        // In the pages' order, each once.
        let sections = found.map(\.section).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // Return opens the first page found.
                SettingsSearch(query: $query) { if let first = found.first { tab.settings = first } }
                    .padding(.bottom, 10)
                ForEach(sections, id: \.self) { section in
                    Text(section)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, section == sections.first ? 0 : 12)
                        .padding(.bottom, 4)
                    ForEach(found.filter { $0.section == section }) { page in
                        SettingsNavRow(page: page, selected: page == open) { tab.settings = page }
                    }
                }
                if found.isEmpty {
                    Text("No settings found")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 220)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(open.title)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.leading, 12)
                        .padding(.bottom, 14)
                    switch open {
                    case .general:
                        GeneralSettings(browser: browser, languages: languages, editLanguages: { editingLanguages = true },
                                        openReleaseNotes: { tab.settings = .releaseNotes })
                    case .appearance:
                        AppearanceSettings()
                    case .privacy:
                        PrivacySettings(browser: browser) { deletingData = true }
                    case .extensions:
                        ExtensionsSettings(browser: browser)
                    case .shortcuts:
                        ShortcutsSettings()
                    case .releaseNotes:
                        ReleaseNotesSettings()
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
                .dialogBlur(editingLanguages || deletingData)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            // An open list stays where its button was: it goes when that moves.
            // Only then: set on every frame of a scroll, the page would be laid out again each time.
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { _, _ in if dropdown != nil { dropdown = nil } }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
            .overlay {
                if editingLanguages {
                    LanguagesDialog(languages: languages, escapes: dropdown == nil) { saved in
                        if let saved {
                            PreferredLanguage.save(saved)
                            languages = saved
                        }
                        editingLanguages = false
                    }
                }
                if deletingData {
                    DeleteDataDialog(browser: browser, escapes: dropdown == nil) { deletingData = false }
                }
            }
        }
        .padding(.top, 2)
        .dropdownHost($dropdown)
    }
}

private struct GeneralSettings: View {
    let browser: Browser
    let languages: [String]
    let editLanguages: () -> Void
    let openReleaseNotes: () -> Void

    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @AppStorage(PictureInPicture.key) private var pictureInPicture = false
    @AppStorage(PictureInPicture.appsKey) private var pictureInPictureForApps = false
    @AppStorage(Screenshot.key) private var screenshot = true
    @AppStorage(SpellCheck.key) private var spellCheck = true
    @AppStorage(QuitConfirmation.key) private var warnsBeforeQuitting = true

    var body: some View {
        DefaultBrowserCard()
        SettingsGroup(title: "Preferences") {
            SettingsRow(title: "Default search engine", detail: "Used for searches from the address bar", icon: "magnifyingglass") {
                DropdownButton(label: engine.name, site: engine.site,
                               options: SearchEngine.allCases.map { DropdownOption(id: $0.rawValue, title: $0.name, site: $0.site) },
                               selected: engine.rawValue) { engine = SearchEngine(rawValue: $0) ?? .google }
            }
        }
        SettingsGroup {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Auto Picture-in-Picture", detail: "Show floating player when switching from a video tab",
                            icon: "pip") {
                    SettingsToggle(title: "Auto Picture-in-Picture", isOn: $pictureInPicture)
                }
                if pictureInPicture {
                    // Under the title, past the icon (SettingsRow).
                    Toggle("Also when switching to another app", isOn: $pictureInPictureForApps)
                        .toggleStyle(SettingsCheckbox())
                        .padding(.leading, 45)
                        .padding(.bottom, 14)
                }
            }
            SettingsRow(title: "Screenshot", detail: "Capture the current page from the right-click menu", icon: "camera.viewfinder") {
                SettingsToggle(title: "Screenshot", isOn: $screenshot)
            }
        }
        SettingsGroup {
            SettingsRow(title: "Preferred languages", detail: languagesDetail, icon: "globe") {
                Button("Configure", systemImage: "slider.horizontal.3", action: editLanguages)
                    .buttonStyle(SettingsButtonStyle())
            }
            SettingsRow(title: "Spell check", detail: "Check spelling as you type", icon: "textformat.abc") {
                // Stored by WebKit itself, which the toggle hears back.
                SettingsToggle(title: "Spell check", isOn: Binding(get: { spellCheck }, set: {
                    SpellCheck.set($0, pages: browser.tabs.compactMap(\.page))
                }))
            }
        }
        SettingsGroup {
            SettingsRow(title: "Warn before quitting", detail: "Ask before ⌘Q closes every window", icon: "power") {
                SettingsToggle(title: "Warn before quitting", isOn: $warnsBeforeQuitting)
            }
        }
        AboutSettings(openReleaseNotes: openReleaseNotes)
    }

    /// Sites are told a new first language only from the next launch on.
    private var languagesDetail: String {
        let names = languages.map(PreferredLanguage.name).joined(separator: ", ")
        return languages.first == PreferredLanguage.current ? names : "\(names), once Nerda restarts"
    }
}

/// How Nerda looks, in System Settings' own order: the theme, the zoom pages
/// open at, where the tabs go, and how much of the desktop shows through.
private struct AppearanceSettings: View {
    @AppStorage(Theme.key) private var theme = Theme.system
    @AppStorage(PageZoom.key) private var zoom = 1.0
    @AppStorage(TabStyle.key) private var tabStyle = TabStyle.vertical
    @AppStorage(Transparency.key) private var transparency = Transparency.transparent

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Theme", detail: "Light, dark, or the same as macOS") {
                DropdownButton(label: theme.name, symbol: theme.symbol,
                               options: Theme.allCases.map { DropdownOption(id: $0.rawValue, title: $0.name, symbol: $0.symbol) },
                               selected: theme.rawValue) { theme = Theme(rawValue: $0) ?? .system }
            }
            SettingsRow(title: "Zoom level", detail: "The size pages open at. ⌘+ and ⌘− change it for one page") {
                DropdownButton(label: PageZoom.name(zoom),
                               options: PageZoom.levels.map { DropdownOption(id: "\($0)", title: PageZoom.name($0)) },
                               selected: "\(CGFloat(zoom))") { zoom = Double($0) ?? 1 }
            }
            SettingsRow(title: "Tab style", detail: "Tabs in a sidebar down the side, or in a row across the top",
                        alignment: .top) {
                PicturePicker(options: TabStyle.allCases, selection: $tabStyle, name: \.name) { TabStylePicture(style: $0) }
            }
            SettingsRow(title: "Transparency", detail: "How much of your desktop shows through around the page",
                        alignment: .top) {
                PicturePicker(options: Transparency.allCases, selection: $transparency, name: \.name) {
                    TransparencyPicture(transparency: $0)
                }
            }
        }
        .onChange(of: theme) { Theme.apply() }
        .onChange(of: zoom) { old, new in
            for window in NSApp.windows {
                (window as? BrowserWindow)?.browser.tabs.forEach { $0.defaultZoomChanged(from: old, to: new) }
            }
        }
    }
}

/// What Nerda keeps of where you have been, and what it lets pages load.
private struct PrivacySettings: View {
    let browser: Browser
    let deleteData: () -> Void

    @Bindable private var blocker = Blocker.shared

    var body: some View {
        SettingsGroup(title: "Browsing history") {
            SettingsRow(title: "Delete browsing history", detail: "Delete history, cookies, cache, and more", icon: "trash") {
                Button("Delete", role: .destructive, action: deleteData)
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
            SettingsLink(title: "View browsing history", icon: "clock.arrow.circlepath", action: browser.openHistory)
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
    }

    private var blockDetail: String {
        if blocker.refreshing { return "Updating filters…" }
        if blocker.failed { return "Some filters couldn't be updated. Nerda tries again later" }
        guard let updated = blocker.updated else { return "If a site has trouble, turn this off and reload it" }
        return "Last updated \(updated.formatted(.relative(presentation: .named)))"
    }
}

/// Chrome extensions: the two ways in (the Chrome Web Store, or a folder),
/// and what is installed, each turned on or off, set up or removed.
private struct ExtensionsSettings: View {
    let browser: Browser

    @State private var link = ""
    private var extensions: Extensions { .shared }

    var body: some View {
        SettingsGroup(title: "Add extensions") {
            SettingsLink(title: "Chrome Web Store", detail: "Find one, and press Add to Nerda on its page", icon: "bag") {
                browser.open(WebStore.home)
            }
            SettingsRow(title: "Add from a link", icon: "link") {
                HStack(spacing: 8) {
                    TextField("Store link or extension ID", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(add)
                    if extensions.busy != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add", action: add)
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(Crx.id(in: link) == nil)
                    }
                }
            }
        }
        SettingsGroup(title: "Installed") {
            if extensions.installed.isEmpty {
                SettingsRow(title: "No extensions yet", icon: "puzzlepiece.extension") { EmptyView() }
            }
            ForEach(extensions.installed) { item in
                InstalledRow(item: item)
            }
        }
        SettingsGroup(title: "Developer") {
            SettingsRow(title: "Load unpacked", detail: "A folder with a manifest.json. Reload picks up what you change in it", icon: "folder") {
                Button("Choose…", action: extensions.installFolder)
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    private func add() {
        guard Crx.id(in: link) != nil else { return }
        extensions.install(from: link)
        link = ""
    }
}

private struct InstalledRow: View {
    let item: InstalledExtension
    private var extensions: Extensions { .shared }

    var body: some View {
        let context = extensions.contexts[item.id]
        HStack(spacing: 12) {
            Group {
                if let icon = context?.webExtension.icon(for: CGSize(width: 40, height: 40)) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.muted)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(detail(context))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .help((extensions.errors[item.id] ?? []).joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            if context?.optionsPageURL != nil {
                Button("Options") { extensions.openOptions(item.id) }
                    .buttonStyle(SettingsButtonStyle())
            }
            Menu {
                Button(item.pinned == true ? "Unpin from Address Bar" : "Pin to Address Bar") {
                    extensions.setPinned(item.id, item.pinned != true)
                }
                if context?.overrideNewTabPageURL != nil {
                    let on = extensions.showsNewTab(item.id)
                    Button(on ? "Stop Showing in New Tabs" : "Show in New Tabs") { extensions.setShowsNewTab(item.id, !on) }
                }
                if item.source != nil || !item.fromStore { Button("Reload") { extensions.reload(item.id) } }
                if item.fromStore, let url = URL(string: "https://chromewebstore.google.com/detail/\(item.id)") {
                    Button("View in Chrome Web Store") { extensions.browser?.open(url) }
                }
                Divider()
                Button("Remove from Nerda…") { extensions.confirmRemove(item.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(Palette.muted)
            .fixedSize()
            SettingsToggle(title: item.name, isOn: Binding(get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }))
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
    }

    private func detail(_ context: WKWebExtensionContext?) -> String {
        _ = extensions.settingsChanged
        var parts = ["Version \(item.version)", item.fromStore ? "Chrome Web Store"
                     : item.source.map { "From “\(URL(fileURLWithPath: $0).lastPathComponent)”" } ?? "From a folder"]
        if item.enabled, context == nil { parts.append("couldn't start") }
        if context?.overrideNewTabPageURL != nil, extensions.showsNewTab(item.id) { parts.append("shows in new tabs") }
        let warnings = extensions.errors[item.id]?.count ?? 0
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts.joined(separator: " · ")
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
        let pages = History.shared.visits.values.count { $0.last >= since }
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
        if history { History.shared.remove(since: since) }
        if downloads {
            for window in NSApp.windows { (window as? BrowserWindow)?.browser.clearDownloads(since: since) }
        }
        let types = (cache ? Self.cacheTypes : []).union(cookies ? Self.cookieTypes : []).union(storage ? Self.storageTypes : [])
        if !types.isEmpty { await browser.dataStore.removeData(ofTypes: types, modifiedSince: since) }
        done()
    }
}

/// A square that fills in the text's colour when ticked, as Aside's do,
/// rather than the system's accent-blue box.
private struct SettingsCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                shape
                    .fill(configuration.isOn ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.clear))
                    .overlay(shape.strokeBorder(configuration.isOn ? .clear : Palette.muted, lineWidth: 1))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.ground)
                        }
                    }
                    .frame(width: 15, height: 15)
                configuration.label
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Configure, by Manage filters: the filter lists, opened under it.
private struct FiltersButton: View {
    @Environment(\.openDropdown) private var open
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            open(Dropdown(anchor: frame, below: true, options: [], selected: nil, choose: { _ in },
                          panel: (AnyView(FiltersPanel()), CGSize(width: 330, height: 440))))
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

/// A row that takes you somewhere else, the whole of it a button.
private struct SettingsLink: View {
    let title: String
    var detail: String?
    var icon: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title, detail: detail, icon: icon) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Every key the browser answers to, by what it works on. Written out here,
/// as the menu bar has no room for what each does.
private struct ShortcutsSettings: View {
    typealias Shortcut = (title: String, detail: String, keys: String)

    static let groups: [(title: String, shortcuts: [Shortcut])] = [
        ("Tabs", [
            ("New Tab", "Open a new tab", "⌘T"),
            ("Close Tab", "Close the tab on screen. A pinned site keeps its tile", "⌘W"),
            ("Search Tabs", "Find an open tab, or a site from your history", "⇧⌘A"),
            ("Next Tab", "Go to the next tab, round from the last to the first", "⌃Tab"),
            ("Previous Tab", "Go to the tab before", "⌃⇧Tab"),
            ("Go to a Tab", "The first eight tabs, in order", "⌘1 – ⌘8"),
            ("Last Tab", "Go to the last tab", "⌘9"),
            ("Collapse Tabs", "Show or hide the sidebar", "⌘S"),
        ]),
        ("Page", [
            ("Open Location", "Type an address or a search", "⌘L"),
            ("Back", "Go to the previous page", "⌘["),
            ("Forward", "Go to the next page", "⌘]"),
            ("Reload Page", "Load the page again", "⌘R"),
            ("Hard Reload Page", "Load the page again, fresh from the site", "⇧⌘R"),
            ("Find", "Search for text on the page", "⌘F"),
            ("Find Next", "Go to the next match", "⌘G"),
            ("Find Previous", "Go to the match before", "⇧⌘G"),
            ("Zoom In", "Make the page bigger", "⌘+"),
            ("Zoom Out", "Make the page smaller", "⌘−"),
            ("Actual Size", "Back to the zoom pages open at", "⌘0"),
        ]),
        ("Nerda", [
            ("New Incognito Window", "Browse without saving history", "⇧⌘N"),
            ("Close Window", "Close the window and its tabs", "⇧⌘W"),
            ("Show All History", "Every page you have visited", "⌘Y"),
            ("Settings", "Open Nerda's settings", "⌘,"),
            ("Minimize", "Put the window in the Dock", "⌘M"),
            ("Hide Nerda", "Hide Nerda's windows", "⌘H"),
            ("Quit Nerda", "Close Nerda. Your tabs come back next time", "⌘Q"),
        ]),
    ]

    var body: some View {
        ForEach(Self.groups, id: \.title) { group in
            SettingsGroup(title: group.title) {
                ForEach(group.shortcuts, id: \.title) { shortcut in
                    SettingsRow(title: shortcut.title, detail: shortcut.detail) {
                        Text(shortcut.keys)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }
}

/// A choice shown as pictures, as System Settings shows Light and Dark: the
/// one chosen ringed in the accent colour, its name bold under it.
private struct PicturePicker<Value: Hashable, Picture: View>: View {
    let options: [Value]
    @Binding var selection: Value
    let name: (Value) -> String
    @ViewBuilder let picture: (Value) -> Picture

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                Button { selection = option } label: {
                    VStack(spacing: 5) {
                        picture(option)
                            .frame(width: 72, height: 46)
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(lineWidth: 2.5)
                                .animation(fade) { $0.foregroundStyle(chosen ? Color.accentColor : .clear) })
                        // The hidden semibold copy holds the width, so choosing
                        // an option never moves the pictures beside it.
                        Text(name(option))
                            .font(.system(size: 12, weight: .semibold))
                            .hidden()
                            .overlay(Text(name(option)).animation(fade) {
                                $0.font(.system(size: 12, weight: chosen ? .semibold : .regular))
                                    .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                            })
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name(option))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    /// Only the ring and the name fade: the page around the picker moves when
    /// the tab style changes, and the picker moves with it, in one step.
    private let fade = Animation.easeOut(duration: 0.14)
}

/// The desktop the little windows sit on: blue, with light sweeping across
/// it, as macOS's own pictures.
private struct Desktop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.52, green: 0.77, blue: 1), Color(red: 0.08, green: 0.3, blue: 0.86)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 80, height: 34)
                    .rotationEffect(.degrees(-24))
                    .offset(x: -18, y: 12)
                    .blur(radius: 3)
            }
            .overlay {
                Ellipse()
                    .fill(Color(red: 0.02, green: 0.16, blue: 0.62))
                    .frame(width: 70, height: 30)
                    .rotationEffect(.degrees(-28))
                    .offset(x: 26, y: 20)
                    .blur(radius: 5)
            }
    }
}

/// A window in little, on the desktop through its glass: its tabs down a
/// sidebar, or across the top, the one on screen lit, and the page's card.
private struct TabStylePicture: View {
    let style: TabStyle

    var body: some View {
        let line = Palette.muted.opacity(0.7)
        ZStack(alignment: .topLeading) {
            Desktop()
            Rectangle().fill(.regularMaterial)
            HStack(spacing: 1.5) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }
            .frame(height: 3.5)
            .offset(x: 4, y: 4)
            if style == .vertical {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Palette.ink.opacity(0.6)).frame(width: 11, height: 2)
                        .padding(.horizontal, 2.5).padding(.vertical, 2)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                    ForEach([9.0, 12, 8], id: \.self) { width in
                        Capsule().fill(line).frame(width: width, height: 2).padding(.leading, 2.5)
                    }
                }
                .offset(x: 3, y: 12)
                card(corners: 3)
                    .padding([.top, .bottom, .trailing], 2)
                    .padding(.leading, 22)
            } else {
                UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5, style: .continuous)
                    .fill(Palette.ground)
                    .frame(width: 18, height: 8)
                    .offset(x: 19, y: 3)
                Capsule().fill(line).frame(width: 10, height: 2).offset(x: 42, y: 6)
                card(corners: 0)
                    .padding(.top, 11)
            }
        }
    }

    /// The page, under its address bar.
    private func card(corners: CGFloat) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: corners, bottomTrailingRadius: corners,
                               topTrailingRadius: corners, style: .continuous)
            .fill(Palette.ground)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    Capsule().fill(Palette.muted.opacity(0.7)).frame(width: 5, height: 2)
                    Capsule().fill(Palette.muted.opacity(0.35)).frame(width: 22, height: 2)
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            }
    }
}

/// The desktop through a card of glass, clear, or tinted most of the way to solid.
private struct TransparencyPicture: View {
    let transparency: Transparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Desktop()
            .overlay(alignment: .topLeading) {
                Group {
                    if transparency == .tinted {
                        shape.fill(.regularMaterial).overlay(shape.fill(Palette.tint))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .frame(width: 64, height: 42)
                // Running off the bottom right, as a window bigger than the picture.
                .offset(x: 16, y: 12)
            }
    }
}

private struct DefaultBrowserCard: View {
    @State private var isDefault = false
    @State private var changing = false
    @State private var message: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isDefault ? "\(Edition.name) is your default browser" : "Make \(Edition.name) your default browser")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(isDefault ? "Links from other apps open here automatically." : "Open links from Mail, Messages, and other apps here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Default browser")
                } else {
                    Button(changing ? "Confirm in macOS…" : "Make default", action: makeDefault)
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .fixedSize()
                        .disabled(changing)
                        .accessibilityLabel("Make \(Edition.name) the default browser")
                }
            }
            if let message, !isDefault {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.045), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private static func handles(_ scheme: String) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!)
        else { return false }
        return Bundle(url: app)?.bundleIdentifier == identifier
    }

    private func refresh() {
        isDefault = ["http", "https"].allSatisfy(Self.handles)
    }

    private func makeDefault() {
        guard !changing else { return }
        changing = true
        message = nil
        Task {
            defer {
                refresh()
                changing = false
            }
            do {
                for scheme in ["http", "https"] where !Self.handles(scheme) {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                }
            } catch {
                message = "Default browser wasn't changed. Try again, or choose \(Edition.name) in System Settings > Desktop & Dock."
            }
        }
    }
}

private struct AboutSettings: View {
    let openReleaseNotes: () -> Void

    private let updater = Updater.shared

    var body: some View {
        SettingsGroup(title: "About Nerda") {
            SettingsRow(title: "Browser", detail: "Current version is v\(Updater.current). \(Edition.updates ? updater.state.detail : "Development build. Updates are disabled.")") {
                if updater.found != nil {
                    Button("Install update", action: updater.install)
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .fixedSize()
                        .disabled(updater.state.isBusy)
                } else {
                    Button("Check for updates") { updater.check(asked: true) }
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .fixedSize()
                        .disabled(!updater.canCheck)
                }
            }
            .padding(.vertical, 6)
            SettingsLink(title: "Release notes", detail: "What each version brought", icon: "sparkles", action: openReleaseNotes)
        }
        VStack(alignment: .leading, spacing: 3) {
            if let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String {
                Text(copyright)
            }
            Text("Nerda is made possible by the [WebKit](https://webkit.org/) open source project. [Source code](https://github.com/kamafozilov/nerda.browser).")
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .tint(.accentColor)
        .textSelection(.enabled)
        .padding(.horizontal, 13)
        .padding(.top, 4)
    }
}

/// What every version brought, from CHANGELOG.md in the bundle, newest
/// first, the one running marked.
private struct ReleaseNotesSettings: View {
    var body: some View {
        ForEach(ReleaseNotes.all) { release in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ReleaseHeading(release: release)
                    if release.version == Updater.current {
                        Text("Installed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 22)
                ReleaseNotesList(notes: release.notes)
                    .padding(16)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// The languages sites are asked for, in order, over the settings until
/// saved or let go: each can be dragged up or down, changed, or taken off.
private struct LanguagesDialog: View {
    let original: [String]
    /// Whether Esc is its own, not an open list's.
    let escapes: Bool
    /// The list to keep, or nil to keep none.
    let done: ([String]?) -> Void

    @State private var languages: [String]
    /// The row being dragged, how far, and how much of that its moves took up.
    @State private var drag: (language: String, offset: CGFloat, taken: CGFloat)?

    private static let rowHeight: CGFloat = 49

    init(languages: [String], escapes: Bool, done: @escaping ([String]?) -> Void) {
        original = languages
        self.escapes = escapes
        self.done = done
        _languages = State(initialValue: languages)
    }

    var body: some View {
        SettingsDialog(width: 520, escapes: escapes, cancel: { done(nil) }) {
            Text("Preferred languages")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Websites use the first language in this list they have. Nerda uses it from its next launch.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
                .padding(.bottom, 16)
            ForEach(languages, id: \.self) { language in
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                row(language)
            }
            DropdownButton(label: "Add", icon: "plus", options: options(besides: languages),
                           selected: nil, below: true) { languages.append($0) }
                .padding(.top, 14)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(nil) }
                    .buttonStyle(SettingsButtonStyle())
                Button("Save") { done(languages) }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(languages == original)
            }
            .padding(.top, 16)
        }
    }

    private func row(_ language: String) -> some View {
        let index = languages.firstIndex(of: language) ?? 0
        let dragged = drag?.language == language
        return HStack(spacing: 10) {
            Grip()
                .frame(width: 16, height: Self.rowHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { move(language, by: $0.translation.height) }
                    .onEnded { _ in withAnimation(.snappy(duration: 0.2)) { drag = nil } })
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            DropdownButton(label: PreferredLanguage.name(language),
                           options: options(besides: languages.filter { $0 != language }),
                           selected: language) { languages[index] = $0 }
            Spacer(minLength: 0)
            Button { languages.remove(at: index) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Sites have to be asked for some language.
            .disabled(languages.count == 1)
            .help("Remove")
        }
        .frame(height: Self.rowHeight)
        .background(dragged ? Palette.ground : .clear)
        .offset(y: dragged ? drag!.offset - drag!.taken : 0)
        .zIndex(dragged ? 1 : 0)
    }

    /// Past half a row, the dragged one swaps with its neighbour.
    private func move(_ language: String, by offset: CGFloat) {
        guard let index = languages.firstIndex(of: language) else { return }
        var taken = drag?.language == language ? drag!.taken : 0
        let target = min(max(index + Int(((offset - taken) / Self.rowHeight).rounded()), 0), languages.count - 1)
        if target != index {
            withAnimation(.snappy(duration: 0.2)) {
                languages.move(fromOffsets: [index], toOffset: target > index ? target + 1 : target)
            }
            taken += CGFloat(target - index) * Self.rowHeight
        }
        drag = (language, offset, taken)
    }

    /// Every language not already listed.
    private func options(besides listed: [String]) -> [DropdownOption] {
        PreferredLanguage.all.filter { !listed.contains($0) }.map { DropdownOption(id: $0, title: PreferredLanguage.name($0)) }
    }
}

/// A dialog over the settings, which dim under it (and blur, `dialogBlur`): a click on them, or Esc
/// (when an open list isn't taking it), lets it go.
private struct SettingsDialog<Content: View>: View {
    let width: CGFloat
    let escapes: Bool
    let cancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous)
                .fill(.black.opacity(0.35))
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(20)
                .frame(width: width)
                .background(Palette.ground, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .accessibilityAddTraits(.isModal)
        }
        .background {
            if escapes {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }
}

/// Six dots: what a row is dragged by.
private struct Grip: View {
    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(Palette.muted)
    }
}

/// A list a `DropdownButton` opened: where the button is, what it offers,
/// which is chosen, and what choosing does. Drawn over everything by the
/// settings (`DropdownPanel`), so no card or dialog cuts it off.
struct Dropdown {
    static let space = "settings"

    let anchor: CGRect
    /// Under the button (to add something), or over it, the chosen one where it was.
    let below: Bool
    let options: [DropdownOption]
    let selected: String?
    let choose: (String) -> Void
    /// Something of its own in place of the options, this big (the filter
    /// lists), its right edge under the button's.
    var panel: (content: AnyView, size: CGSize)?
}

struct DropdownOption {
    let id: String
    let title: String
    /// The site whose icon it is shown with.
    var site: URL?
    /// Or the symbol.
    var symbol: String?
    /// A line under it, between it and the rest.
    var separated = false
}

extension EnvironmentValues {
    @Entry var openDropdown: (Dropdown) -> Void = { _ in }
}

extension View {
    /// A page under a `SettingsDialog`, out of focus, as Aside's is. Blurred
    /// itself: a material over it would show the desktop instead.
    func dialogBlur(_ open: Bool) -> some View {
        blur(radius: open ? 6 : 0)
            .animation(.easeOut(duration: 0.15), value: open)
    }

    /// Where the `DropdownButton`s in it open their lists: over all of it.
    func dropdownHost(_ dropdown: Binding<Dropdown?>) -> some View {
        coordinateSpace(.named(Dropdown.space))
            .environment(\.openDropdown) { dropdown.wrappedValue = $0 }
            .overlay(alignment: .topLeading) {
                if let open = dropdown.wrappedValue { DropdownPanel(dropdown: open) { dropdown.wrappedValue = nil } }
            }
    }
}

/// A choice among several, as a button that opens them in a list: its label
/// is what is chosen (with its site's icon), or with an icon, what it does.
private struct DropdownButton: View {
    let label: String
    var site: URL?
    /// The chosen one's symbol, before its name.
    var symbol: String?
    var icon: String?
    let options: [DropdownOption]
    let selected: String?
    var below = false
    /// As wide as it is given, as a field, its chevron at the far end.
    var fill = false
    let choose: (String) -> Void

    @Environment(\.openDropdown) private var open
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            open(Dropdown(anchor: frame, below: below, options: options,
                          selected: selected, choose: choose))
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                if let site { Favicon(site: site, size: 14, plate: false) }
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(label)
                if fill { Spacer(minLength: 0) }
                if icon == nil {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: fill ? .infinity : nil)
        }
        .buttonStyle(SettingsButtonStyle())
        .fixedSize(horizontal: !fill, vertical: true)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Dropdown.space)) } action: { frame = $0 }
    }
}

/// The open list, on the menus' own panel. A click anywhere else or Esc puts it away.
private struct DropdownPanel: View {
    let dropdown: Dropdown
    let close: () -> Void

    /// The row under the pointer, the chosen one to begin with.
    @State private var lit: String?

    private static let rowHeight: CGFloat = 32
    private static let separatorHeight: CGFloat = 9

    var body: some View {
        GeometryReader { space in
            let lines = CGFloat(dropdown.options.count { $0.separated }) * Self.separatorHeight
            let panel = dropdown.panel
            let height = panel?.size.height ?? min(CGFloat(dropdown.options.count), 8.5) * Self.rowHeight + lines + 10
            let width = panel?.size.width ?? max(dropdown.anchor.width + 10, 200)
            let left = panel == nil ? dropdown.anchor.minX - 5 : dropdown.anchor.maxX - width
            let top = dropdown.below ? dropdown.anchor.maxY + 4 : dropdown.anchor.minY - 5
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                Group {
                    if let panel { panel.content } else { list }
                }
                .frame(width: width, height: height)
                .menuPanel()
                // Kept inside the settings, whichever edge it is near.
                .offset(x: max(8, min(left, space.size.width - width - 8)),
                        y: max(8, min(top, space.size.height - height - 8)))
            }
        }
        .background {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .onAppear { lit = dropdown.selected }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(dropdown.options, id: \.id) { option in
                        row(option)
                        if option.separated {
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                                .padding(.horizontal, 4)
                                .frame(height: Self.separatorHeight)
                        }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { if let selected = dropdown.selected { proxy.scrollTo(selected, anchor: .center) } }
        }
    }

    private func row(_ option: DropdownOption) -> some View {
        Button {
            close()
            dropdown.choose(option.id)
        } label: {
            HStack(spacing: 10) {
                if let site = option.site { Favicon(site: site, size: 16, plate: false) }
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 16)
                }
                Text(option.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if option.id == dropdown.selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit == option.id ? Palette.wash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { lit = option.id } }
        .id(option.id)
    }
}

struct SettingsSearch: View {
    @Binding var query: String
    var prompt = "Search…"
    let submit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(submit)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color.primary.opacity(0.03), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct SettingsNavRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.wash : hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Settings that belong together, on one card under their heading, with a
/// line between one and the next.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 12)
                    .padding(.top, 22)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        }
                        row
                    }
                }
            }
            .background(Color.primary.opacity(0.045))
            // A row lit under the pointer keeps to the card's corners.
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// One setting: what it is, a line on what it does, and its control at the
/// end; level with the top of a tall one (pictures to pick from).
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var icon: String?
    var alignment = VerticalAlignment.center
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 13)
        .padding(.vertical, alignment == .top ? 12 : 0)
        .frame(minHeight: 52)
    }
}

/// Buttons on the settings' cards: outlined, or, for the one thing to do on a
/// card (checking for updates), filled in the text's colour; one that
/// deletes (`role: .destructive`), red on a wash of red.
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let destructive = configuration.role == .destructive
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? AnyShapeStyle(.red) : prominent ? AnyShapeStyle(Palette.ground) : AnyShapeStyle(Palette.ink))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(destructive ? AnyShapeStyle(Color.red.opacity(0.15))
                        : prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Color.primary.opacity(0.05)), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(prominent || destructive ? 0 : 0.12)))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}

private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(.green)
    }
}
