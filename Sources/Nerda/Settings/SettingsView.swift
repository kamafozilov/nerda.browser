import SwiftUI

/// The pages of Nerda's settings, listed down the settings tab's left. Only
/// what works is listed: a page comes once it has something in it.
enum SettingsPage: String, CaseIterable, Identifiable, Codable {
    case general, appearance, tabs, passwords, autofill, siteSettings, privacy, profiles, extensions, shortcuts, releaseNotes

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tabs: "Tabs"
        case .passwords: "Vault"
        case .autofill: "AutoFill"
        case .siteSettings: "Site Settings"
        case .privacy: "Security & Privacy"
        case .profiles: "Profiles"
        case .extensions: "Extensions"
        case .shortcuts: "Keyboard Shortcuts"
        case .releaseNotes: "Release Notes"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .tabs: "square.on.square"
        case .passwords: "key"
        case .autofill: "person.text.rectangle"
        case .siteSettings: "slider.horizontal.3"
        case .privacy: "lock"
        case .profiles: "person.crop.circle"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "keyboard"
        case .releaseNotes: "sparkles"
        }
    }

    /// The heading it is listed under.
    var section: String {
        switch self {
        case .general, .appearance, .tabs, .passwords, .autofill, .siteSettings, .privacy, .profiles, .extensions, .shortcuts: "Personal"
        case .releaseNotes: "Nerda"
        }
    }

    /// What the page holds, so a search finds it by a setting as well as by its name.
    private var keywords: [String] {
        switch self {
        case .general: ["default browser", "search engine", "google", "kagi", "ecosia", "startpage", "perplexity", "custom search", "suggestions", "picture in picture", "video", "screenshot", "language", "spell",
                        "downloads", "folder", "ask where to save", "bookmarks", "import", "export", "quit", "warn", "about", "version", "updates", "automatically"]
        case .appearance: ["theme", "dark", "light", "zoom", "tab style", "vertical", "horizontal", "sidebar", "transparency", "tinted", "transparent", "glass",
                           "new tab", "wallpaper", "picture", "background", "ai chats", "chatgpt", "claude"]
        case .tabs: ["sleep", "memory", "performance", "inactive", "background", "load", "wait", "lazy", "pinned", "launch", "startup", "preview", "hover", "card"]
        case .passwords: ["autofill", "fill", "save", "never saved", "import", "keychain", "touch id", "accounts", "sign in", "login"]
        case .autofill: ["contact info", "addresses", "credit cards", "debit cards", "payment", "forms", "fill", "name", "email", "phone",
                         "shipping", "billing", "checkout"]
        case .siteSettings: ["permissions", "camera", "microphone", "location", "notifications", "pop-ups", "popups", "sites", "allow", "block", "ads"]
        case .privacy: ["security", "https", "secure connections", "upgrade", "history", "keep history", "delete", "clear", "cookies", "cache", "site data", "ads", "trackers", "adblock", "blocking",
                        "filters", "easylist", "ublock", "adguard", "incognito", "private", "lock"]
        case .profiles: ["work", "personal", "school", "separate", "new profile", "window", "accounts", "cookies", "rename", "delete"]
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
    @State private var editingSearch = false
    @State private var deletingData = false
    @State private var languages = PreferredLanguage.chosen
    /// An address or card being added or changed (Settings › AutoFill).
    @State private var editingContact: Contact?
    @State private var editingCard: Card?
    /// A profile being made or changed, and one about to be deleted (Settings › Profiles).
    @State private var editingProfile: ProfileDraft?
    @State private var deletingProfile: Profile?

    var body: some View {
        let open = tab.settings.flatMap { $0 != .extensions || Extensions.available ? $0 : nil } ?? .general
        let found = SettingsPage.allCases.filter { ($0 != .extensions || Extensions.available) && $0.matches(query) }
        // In the pages' order, each once.
        let sections = found.map(\.section).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // Return opens the first page found.
                SettingsSearch(query: $query) { if let first = found.first { tab.content = .settings(first) } }
                    .padding(.bottom, 10)
                ForEach(sections, id: \.self) { section in
                    Text(section)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, section == sections.first ? 0 : 12)
                        .padding(.bottom, 4)
                    ForEach(found.filter { $0.section == section }) { page in
                        SettingsNavRow(page: page, selected: page == open) { tab.content = .settings(page) }
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
                                        editSearch: { editingSearch = true }, openReleaseNotes: { tab.content = .settings(.releaseNotes) })
                    case .appearance:
                        AppearanceSettings()
                    case .tabs:
                        TabsSettings()
                    case .passwords:
                        PasswordsSettings(browser: browser)
                    case .autofill:
                        AutoFillSettings(autofill: browser.profile.autofill, edit: { editingContact = $0 }, editCard: { editingCard = $0 })
                    case .siteSettings:
                        SitePermissionsSettings(browser: browser)
                    case .privacy:
                        PrivacySettings(browser: browser) { deletingData = true }
                    case .profiles:
                        ProfilesSettings(browser: browser) { editingProfile = $0 }
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
                .dialogBlur(editingLanguages || editingSearch || deletingData || editingContact != nil || editingCard != nil
                            || editingProfile != nil || deletingProfile != nil)
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
                if editingSearch {
                    CustomSearchDialog(escapes: dropdown == nil) { editingSearch = false }
                }
                if deletingData {
                    DeleteDataDialog(browser: browser, escapes: dropdown == nil) { deletingData = false }
                }
                if let contact = editingContact {
                    ContactDialog(autofill: browser.profile.autofill, contact: contact, escapes: dropdown == nil) { editingContact = nil }
                }
                if let card = editingCard {
                    CardDialog(autofill: browser.profile.autofill, card: card, escapes: dropdown == nil) { editingCard = nil }
                }
                if let draft = editingProfile {
                    ProfileDialog(draft: draft, escapes: dropdown == nil, delete: { deletingProfile = $0 }) { editingProfile = nil }
                }
                if let profile = deletingProfile {
                    DeleteProfileDialog(profile: profile, escapes: dropdown == nil) { deletingProfile = nil }
                }
            }
        }
        .padding(.top, 2)
        .dropdownHost($dropdown)
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
