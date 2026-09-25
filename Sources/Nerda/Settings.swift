import SwiftUI

/// The pages of Nerda's settings, listed down the settings tab's left. Only
/// what works is listed: a page comes once it has something in it.
enum SettingsPage: String, CaseIterable, Identifiable, Codable {
    case general, appearance, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .shortcuts: "keyboard"
        }
    }

    /// The heading it is listed under.
    var section: String {
        switch self {
        case .general, .appearance, .shortcuts: "Personal"
        }
    }

    /// What the page holds, so a search finds it by a setting as well as by its name.
    private var keywords: [String] {
        switch self {
        case .general: ["default browser", "search engine", "google", "picture in picture", "video", "screenshot", "language", "spell", "ads", "trackers", "blocking", "privacy", "about", "version", "updates"]
        case .appearance: ["theme", "dark", "light", "zoom", "tab style", "vertical", "horizontal", "sidebar", "transparency", "tinted", "transparent", "glass"]
        case .shortcuts: ["keyboard", "keys", "hotkeys"] + ShortcutsSettings.groups.flatMap { $0.shortcuts.map(\.title) }
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
                        GeneralSettings(browser: browser, languages: languages) { editingLanguages = true }
                    case .appearance:
                        AppearanceSettings()
                    case .shortcuts:
                        ShortcutsSettings()
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            // An open list stays where its button was: it goes when that moves.
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { _, _ in dropdown = nil }
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
            }
        }
        .padding(.top, 2)
        .coordinateSpace(.named(Dropdown.space))
        .environment(\.openDropdown) { dropdown = $0 }
        .overlay(alignment: .topLeading) {
            if let dropdown { DropdownPanel(dropdown: dropdown) { self.dropdown = nil } }
        }
    }
}

private struct GeneralSettings: View {
    let browser: Browser
    let languages: [String]
    let editLanguages: () -> Void

    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @AppStorage(PictureInPicture.key) private var pictureInPicture = false
    @AppStorage(Screenshot.key) private var screenshot = true
    @AppStorage(SpellCheck.key) private var spellCheck = true

    var body: some View {
        DefaultBrowserCard()
        SettingsGroup(title: "Preferences") {
            SettingsRow(title: "Default search engine", detail: "Used for searches from the address bar") {
                DropdownButton(label: engine.name, site: engine.site,
                               options: SearchEngine.allCases.map { DropdownOption(id: $0.rawValue, title: $0.name, site: $0.site) },
                               selected: engine.rawValue) { engine = SearchEngine(rawValue: $0) ?? .google }
            }
        }
        SettingsGroup {
            SettingsRow(title: "Block ads and trackers", detail: "If a site has trouble, turn this off and reload it") {
                SettingsToggle(title: "Block ads and trackers", isOn: Binding(
                    get: { Blocker.shared.isEnabled }, set: { Blocker.shared.isEnabled = $0 }
                ))
            }
        }
        SettingsGroup {
            SettingsRow(title: "Auto Picture-in-Picture", detail: "Show floating player when switching from a video tab") {
                SettingsToggle(title: "Auto Picture-in-Picture", isOn: $pictureInPicture)
            }
            SettingsRow(title: "Screenshot", detail: "Capture the current page from the right-click menu") {
                SettingsToggle(title: "Screenshot", isOn: $screenshot)
            }
        }
        SettingsGroup {
            SettingsRow(title: "Preferred languages", detail: languagesDetail) {
                Button("Configure", systemImage: "slider.horizontal.3", action: editLanguages)
                    .buttonStyle(SettingsButtonStyle())
            }
            SettingsRow(title: "Spell check", detail: "Check spelling as you type") {
                // Stored by WebKit itself, which the toggle hears back.
                SettingsToggle(title: "Spell check", isOn: Binding(get: { spellCheck }, set: {
                    SpellCheck.set($0, pages: browser.tabs.compactMap(\.page))
                }))
            }
        }
        AboutSettings()
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
    private let updater = Updater.shared

    var body: some View {
        SettingsGroup(title: "About Nerda") {
            SettingsRow(title: "Browser", detail: "Current version is v\(Updater.current). \(Edition.updates ? updater.state.detail : "Development build. Updates are disabled.")") {
                Button("Check for updates") { updater.check(asked: true) }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .fixedSize()
                    .disabled(!updater.canCheck)
            }
            .padding(.vertical, 6)
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
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous)
                .fill(.black.opacity(0.35))
                .onTapGesture { done(nil) }
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(20)
            .frame(width: 520)
            .background(Palette.ground, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
        .background {
            if escapes {
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
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
}

struct DropdownOption {
    let id: String
    let title: String
    /// The site whose icon it is shown with.
    var site: URL?
    /// Or the symbol.
    var symbol: String?
}

extension EnvironmentValues {
    @Entry var openDropdown: (Dropdown) -> Void = { _ in }
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
                if icon == nil {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .fixedSize()
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

    var body: some View {
        GeometryReader { space in
            let height = min(CGFloat(dropdown.options.count), 8.5) * Self.rowHeight + 10
            let width = max(dropdown.anchor.width + 10, 200)
            let top = dropdown.below ? dropdown.anchor.maxY + 4 : dropdown.anchor.minY - 5
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                list
                    .frame(width: width, height: height)
                    .menuPanel()
                    // Kept inside the settings, whichever edge it is near.
                    .offset(x: min(dropdown.anchor.minX - 5, space.size.width - width - 8),
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
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
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
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.ink)
                    .padding(.trailing, -2)
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
/// card (checking for updates), filled in the text's colour.
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Palette.ground : Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Color.primary.opacity(0.05)), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12)))
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
