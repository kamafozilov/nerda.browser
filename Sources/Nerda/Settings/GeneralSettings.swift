import SwiftUI

struct GeneralSettings: View {
    let browser: Browser
    let languages: [String]
    let editLanguages: () -> Void
    let editSearch: () -> Void
    let openReleaseNotes: () -> Void

    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    // Watched, so the row shows your own engine's name as it is saved.
    @AppStorage(SearchEngine.customNameKey) private var customName = ""
    @AppStorage(SearchEngine.customAddressKey) private var customAddress = ""
    @AppStorage(PictureInPicture.key) private var pictureInPicture = false
    @AppStorage(PictureInPicture.appsKey) private var pictureInPictureForApps = false
    @AppStorage(Screenshot.key) private var screenshot = true
    @AppStorage(SpellCheck.key) private var spellCheck = true
    @AppStorage(QuitConfirmation.key) private var warnsBeforeQuitting = true
    @AppStorage(SearchSuggestions.key) private var suggestions = true
    @AppStorage(Downloads.folderKey) private var downloadFolder: String?
    @AppStorage(Downloads.asksKey) private var asksWhereToSave = false

    var body: some View {
        DefaultBrowserCard()
        // Your own, once it has an address that works; Google until then.
        let current = SearchEngine.current
        let hasCustom = SearchEngine.customAddress != nil
        SettingsGroup(title: "Search") {
            SettingsRow(title: "Default search engine", detail: "Used for searches from the address bar", icon: "magnifyingglass") {
                HStack(spacing: 8) {
                    if current == .custom {
                        Button("Edit…", action: editSearch)
                            .buttonStyle(SettingsButtonStyle())
                    }
                    DropdownButton(label: current.name, site: current.site,
                                   options: SearchEngine.allCases.map { engine in
                                       // Your own last, under a line; until it has an address, Custom… asks for one.
                                       engine == .custom && !hasCustom
                                           ? DropdownOption(id: engine.rawValue, title: "Custom…", symbol: "plus")
                                           : DropdownOption(id: engine.rawValue, title: engine.name, site: engine.site,
                                                            separated: engine == .perplexity)
                                   },
                                   selected: current.rawValue) { picked in
                        let picked = SearchEngine(rawValue: picked) ?? .google
                        if picked == .custom, !hasCustom { editSearch() } else { engine = picked }
                    }
                }
            }
            SettingsRow(title: "Search suggestions",
                        detail: current.suggests ? "\(current.name) suggests searches as you type. Off, nothing leaves your Mac until Return"
                            : "\(current.name) doesn't suggest searches as you type",
                        icon: "text.magnifyingglass") {
                SettingsToggle(title: "Search suggestions", isOn: $suggestions)
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
        SettingsGroup(title: "Downloads") {
            SettingsRow(title: "Download location", detail: (Downloads.folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
                        icon: "folder") {
                Button("Change…", action: chooseDownloadFolder)
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
            SettingsRow(title: "Ask where to save each file", detail: "Choose a folder and a name before a download starts",
                        icon: "questionmark.folder") {
                SettingsToggle(title: "Ask where to save each file", isOn: $asksWhereToSave)
            }
        }
        SettingsGroup(title: "Bookmarks") {
            SettingsRow(title: "Import and export", detail: "From Chrome, Safari, Firefox or Arc, or yours to a file",
                        icon: "book") {
                HStack(spacing: 8) {
                    Button("Import…", action: browser.importBookmarks)
                    Button("Export…", action: browser.exportBookmarks)
                }
                .buttonStyle(SettingsButtonStyle())
                .fixedSize()
            }
        }
        AboutSettings(openReleaseNotes: openReleaseNotes)
    }

    /// Sites are told a new first language only from the next launch on.
    private var languagesDetail: String {
        let names = languages.map(PreferredLanguage.name).joined(separator: ", ")
        return languages.first == PreferredLanguage.current ? names : "\(names), once Nerda restarts"
    }

    /// ~/Downloads chosen again is no choice at all: it follows the Mac's.
    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Downloads.folder
        panel.message = "Choose where downloads go."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL else { return }
        downloadFolder = folder == URL.downloadsDirectory.standardizedFileURL ? nil : folder.path(percentEncoded: false)
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
    @AppStorage(Updater.automaticKey) private var automatic = true

    var body: some View {
        SettingsGroup(title: "About Nerda") {
            SettingsRow(title: "Browser", detail: "Current version is v\(Updater.current). \(Edition.updates ? updater.state.detail : "Development build. Updates are disabled.")") {
                if case .ready = updater.state {
                    Button("Restart to update", action: updater.restart)
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .fixedSize()
                } else if updater.found != nil {
                    Button("Download update", action: updater.download)
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
            if Edition.updates {
                SettingsRow(title: "Check for updates automatically", detail: "Look for a newer Nerda a few times a day", icon: "arrow.triangle.2.circlepath") {
                    SettingsToggle(title: "Check for updates automatically", isOn: $automatic)
                }
            }
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

/// The languages sites are asked for, in order, over the settings until
/// saved or let go: each can be dragged up or down, changed, or taken off.
struct LanguagesDialog: View {
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
                    .onEnded { _ in withAnimation(Motion.moving(.snappy(duration: 0.2))) { drag = nil } })
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
            withAnimation(Motion.moving(.snappy(duration: 0.2))) {
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

/// Your own search engine: a name, and the address searches go to, with %s
/// where what was typed goes. Saved, it is the one searches go to.
struct CustomSearchDialog: View {
    let escapes: Bool
    let done: () -> Void

    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @AppStorage(SearchEngine.customNameKey) private var savedName = ""
    @AppStorage(SearchEngine.customAddressKey) private var savedAddress = ""
    @State private var name = ""
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let valid = SearchEngine.validAddress(address)
        SettingsDialog(width: 400, escapes: escapes, cancel: done) {
            Text("Custom search engine")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Searches from the address bar go to this address, with %s where what you typed goes.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            label("Address")
                .padding(.top, 18)
            TextField("Address", text: $address, prompt: Text(verbatim: "https://example.com/search?q=%s"))
                .labelsHidden()
                .focused($addressFocused)
                .onSubmit(save)
            // Said once something is typed, not while the field is still empty.
            Text(valid == nil && !address.isEmpty ? "Use a web address with %s where the search goes" : " ")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
            label("Name")
                .padding(.top, 10)
            TextField("Name", text: $name, prompt: Text(placeholder(valid)))
                .labelsHidden()
                .onSubmit(save)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(SettingsButtonStyle())
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(valid == nil)
            }
            .padding(.top, 22)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            name = savedName
            address = savedAddress
            addressFocused = true
        }
    }

    /// What it is called if left unnamed: its site.
    private func placeholder(_ valid: String?) -> String {
        valid.flatMap { URL(string: $0.replacingOccurrences(of: "%s", with: "x"))?.host() } ?? "Optional"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.bottom, 8)
    }

    private func save() {
        guard let valid = SearchEngine.validAddress(address) else { return }
        // Short enough for the settings row it is shown in.
        savedName = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        savedAddress = valid
        engine = .custom
        done()
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
