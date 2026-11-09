import SwiftUI

/// The sidebar's bottom-left corner: opens `SidebarMenu`. In an incognito
/// window it wears the incognito mark, as Chrome's profile button does.
struct SidebarMenuButton: View {
    @Binding var shown: Bool
    var incognito = false
    /// The window's profile, marked by its symbol in its colour, as Safari's
    /// toolbar marks it; none with Personal alone.
    var profile: Profile?

    @State private var hovering = false

    var body: some View {
        Button { withAnimation(SidebarMenu.animation) { shown.toggle() } } label: {
            HStack(spacing: 3) {
                if incognito {
                    IncognitoMark(size: 16)
                } else if let profile {
                    Image(systemName: profile.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(profile.color.color)
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(hovering || shown ? Palette.ink : Palette.muted)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || shown ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(incognito ? "Incognito" : profile.map { "\($0.name) Profile" } ?? "Menu")
        .accessibilityLabel(incognito ? "Incognito Menu" : profile.map { "Menu, \($0.name) Profile" } ?? "Menu")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// What the app has besides the tabs, on a panel over the sidebar's bottom
/// corner: History opens to its side, as a submenu does, and so does Developer,
/// the page's developer tools; Passwords, Settings and New Tab
/// with their keys, and an incognito window. Downloads have their own button
/// beside it. Profiles go at its top once there is more than Personal, each
/// opening its own window, the window's own ticked.
/// In an incognito window, no History: it isn't kept there.
/// Drawn by SwiftUI rather than as a system menu, so it can look like the rest,
/// and so worked from the keyboard by hand: ↑ and ↓ light a row, → and
/// Return go into a submenu, ← and Esc come back out, Return picks.
struct SidebarMenu: View {
    let browser: Browser
    /// Under its button at the window's top right (the tabs across the top),
    /// rather than over it in the sidebar's bottom corner.
    var fromTop = false
    let close: () -> Void

    static let width: CGFloat = 240
    static let animation = Animation.snappy(duration: 0.18)

    enum Submenu { case history, developer }

    /// The menu's own rows, top to bottom.
    enum Row: Hashable {
        case profile(UUID), history, vault, settings, developer, newTab, incognito

        var submenu: Submenu? {
            switch self {
            case .history: .history
            case .developer: .developer
            default: nil
            }
        }
    }

    /// A submenu's row.
    struct Item: Identifiable {
        let id: String
        var icon: String?
        var site: URL?
        let title: String
        var shortcut: String?
        var checked = false
        var enabled = true
        /// A line above it, setting it apart from those before.
        var parted = false
        let action: () -> Void
    }

    /// The submenu out beside its row: the one the pointer last went over.
    @State private var open: Submenu?
    /// The row lit from the keyboard (↑ and ↓), as a system menu's; and in
    /// the submenu out, once → or Return went into it.
    @State private var keyed: Row?
    @State private var subKeyed: Item.ID?
    @FocusState private var focused: Bool

    /// Profiles first, once there is more than Personal; no History in an
    /// incognito window, as it isn't kept there.
    static func rows(profiles: [Profile], incognito: Bool) -> [Row] {
        (profiles.count > 1 ? profiles.map { .profile($0.id) } : [])
            + (incognito ? [] : [.history]) + [.vault, .settings, .developer, .newTab, .incognito]
    }

    private var rows: [Row] { Self.rows(profiles: Profiles.shared.all, incognito: browser.isPrivate) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { row in
                view(of: row)
                // Each row's hover says which submenu is out, and puts the
                // keyboard's light out: the pointer has the menu now.
                    .onHover { over in
                        guard over else { return }
                        open = row.submenu
                        keyed = nil
                        subKeyed = nil
                    }
                if case .profile(let id) = row, id == Profiles.shared.all.last?.id { MenuDivider() }
                if row == .developer { MenuDivider() }
            }
        }
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .menuPanel()
        // Esc puts away the submenu gone into, then the menu, as in a system menu.
        .background {
            Button("Close Menu") {
                guard subKeyed == nil else { return leaveSubmenu() }
                close()
                // The keyboard the menu took goes back to the page.
                browser.focusPage()
            }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu")
        // The keyboard comes to the menu as it opens, for ↑ ↓ → ← and Return.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
            key(press.key) ? .handled : .ignored
        }
        .onAppear {
            focused = true
            // Opened from the keyboard, its first row is lit at once.
            if NSApp.currentEvent?.type == .keyDown { keyed = rows.first }
        }
    }

    @ViewBuilder private func view(of row: Row) -> some View {
        switch row {
        case .profile(let id):
            if let profile = Profiles.shared.profile(id) {
                MenuRow(icon: profile.symbol, tint: profile.color.color, title: profile.name,
                        lit: keyed == row, checked: !browser.isPrivate && profile === browser.profile) { activate(row) }
            }
        case .history:
            MenuRow(icon: "clock.arrow.circlepath", title: "History", submenu: true, lit: open == .history || keyed == row) {
                activate(row)
            }
            .overlay(alignment: fromTop ? .topTrailing : .bottomLeading) {
                if open == .history { beside(submenu(historyItems, width: 300, empty: "No history yet")) }
            }
        case .vault:
            MenuRow(icon: "lock.shield", title: "Vault", shortcut: "⌥⌘P", lit: keyed == row) { activate(row) }
        case .settings:
            MenuRow(icon: "gearshape", title: "Settings", shortcut: "⌘,", lit: keyed == row) { activate(row) }
        case .developer:
            MenuRow(icon: "chevron.left.forwardslash.chevron.right", title: "Developer", submenu: true,
                    lit: open == .developer || keyed == row) { activate(row) }
            .overlay(alignment: fromTop ? .topTrailing : .bottomLeading) {
                if open == .developer { beside(submenu(developerItems, width: 290)) }
            }
        case .newTab:
            MenuRow(icon: "plus", title: "New Tab", shortcut: "⌘T", lit: keyed == row) { activate(row) }
        case .incognito:
            MenuRow(mark: true, title: "Incognito Window", shortcut: "⇧⌘N", lit: keyed == row) { activate(row) }
        }
    }

    /// A row picked, by a click or Return: a submenu's comes out, and the
    /// keyboard goes into it.
    private func activate(_ row: Row) {
        if let submenu = row.submenu {
            open = submenu
            if keyed == row { subKeyed = items(of: submenu).first(where: \.enabled)?.id }
            return
        }
        switch row {
        case .profile(let id): if let profile = Profiles.shared.profile(id) { run { Windows.show(profile) } }
        case .vault: run { VaultWindow.show(browser.profile) }
        case .settings: run { browser.openSettings() }
        case .newTab: run(browser.newTab)
        case .incognito: run { Windows.openIncognito() }
        case .history, .developer: break
        }
    }

    /// ↑ and ↓ go from row to row, round past either end, skipping those
    /// greyed; → and Return go into a submenu, ← comes back out of it, and
    /// Return picks the row lit. False for a key left to others.
    private func key(_ key: KeyEquivalent) -> Bool {
        if let open, let subKeyed {
            let items = items(of: open).filter(\.enabled)
            switch key {
            case .upArrow, .downArrow:
                let index = items.firstIndex { $0.id == subKeyed } ?? 0
                let step = key == .downArrow ? 1 : -1
                if !items.isEmpty { self.subKeyed = items[(index + step + items.count) % items.count].id }
            case .leftArrow: leaveSubmenu()
            case .return: items.first { $0.id == subKeyed }?.action()
            default: return false
            }
            return true
        }
        switch key {
        case .upArrow, .downArrow:
            let step = key == .downArrow ? 1 : -1
            let next = keyed.flatMap(rows.firstIndex).map { ($0 + step + rows.count) % rows.count }
                ?? (step > 0 ? 0 : rows.count - 1)
            keyed = rows[next]
            open = nil
        case .rightArrow:
            guard let keyed, keyed.submenu != nil else { return false }
            activate(keyed)
        case .return:
            guard let keyed else { return false }
            activate(keyed)
        default:
            return false
        }
        return true
    }

    private func leaveSubmenu() {
        subKeyed = nil
        open = nil
    }

    private func items(of submenu: Submenu) -> [Item] {
        switch submenu {
        case .history: historyItems
        case .developer: developerItems
        }
    }

    /// A submenu out to the right of its row, level with the row's bottom,
    /// so a long one grows up the window rather than off its bottom. From the
    /// top right, out to the left, level with its top, growing down.
    private func beside(_ content: some View) -> some View {
        content
            .padding(.vertical, 5)
            .menuPanel()
            .fixedSize()
            .offset(x: fromTop ? -(Self.width + 6) : Self.width + 6, y: fromTop ? -5 : 5)
            .transition(.opacity)
    }

    private func submenu(_ items: [Item], width: CGFloat, empty: String? = nil) -> some View {
        VStack(spacing: 0) {
            // Nothing before the first line: nothing visited yet.
            if let empty, items.first?.parted == true {
                Text(empty)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
            }
            ForEach(items) { item in
                if item.parted { MenuDivider() }
                MenuRow(icon: item.icon, site: item.site, title: item.title, shortcut: item.shortcut,
                        lit: subKeyed == item.id, checked: item.checked, action: item.action)
                    .disabled(!item.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .frame(width: width)
    }

    private var historyItems: [Item] {
        let visits = browser.history.recent(12).map { visit in
            Item(id: visit.url.absoluteString, site: visit.url, title: visit.title.isEmpty ? visit.url.absoluteString : visit.title) {
                run { browser.go(to: visit.url) }
            }
        }
        return visits + [
            Item(id: "all", icon: "clock.arrow.circlepath", title: "Show All History", shortcut: "⌘Y", parted: true) {
                run(browser.openHistory)
            },
            Item(id: "clear", icon: "trash", title: "Clear History…") { run(browser.clearHistory) },
        ]
    }

    /// For the page on screen; none without one (a new tab, Settings).
    private var developerItems: [Item] {
        let tab = browser.selected
        let page = tab?.hasPage == true
        return [
            Item(id: "tools", icon: "wrench.and.screwdriver", title: "Developer Tools", shortcut: "⌥⌘I", enabled: page) {
                run { tab?.inspect(.tools) }
            },
            Item(id: "console", icon: "terminal", title: "JavaScript Console", shortcut: "⌥⌘J", enabled: page) {
                run { tab?.inspect(.console) }
            },
            Item(id: "element", icon: "cursorarrow.rays", title: "Inspect Element", shortcut: "⌥⌘C", enabled: page) {
                run { tab?.inspect(.element) }
            },
            Item(id: "responsive", icon: "iphone", title: "Responsive Design Mode", shortcut: "⌥⌘R",
                 checked: tab?.responsive != nil, enabled: page, parted: true) { run(browser.toggleResponsive) },
            Item(id: "source", icon: "doc.plaintext", title: "View Page Source", shortcut: "⌥⌘U",
                 enabled: page && tab?.site?.scheme != ViewSource.scheme) { run(browser.viewSource) },
            Item(id: "javascript", icon: "curlybraces", title: "Disable JavaScript", checked: tab?.javaScriptOff == true,
                 enabled: page, parted: true) { run { tab?.javaScriptOff.toggle() } },
            Item(id: "clear", icon: "trash", title: "Clear Site Data", enabled: page) {
                run { Task { await tab?.clearSiteData() } }
            },
        ]
    }

    /// The menu goes first, as a system menu's does, and then what was picked.
    private func run(_ action: @escaping () -> Void) {
        close()
        action()
    }
}

extension View {
    /// The menu's own look: frosted, rounded, with a fine edge and a shadow
    /// lifting it off what is under it. Tinted with the window's ground, as
    /// `popoverGlass` is: across the top it opens over the page, and frosted
    /// alone it went grey over a white one, its shortcuts fading into it.
    func menuPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return background { shape.fill(.regularMaterial).overlay(shape.fill(Palette.ground.opacity(0.75))) }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}

private struct MenuRow: View {
    var icon: String?
    /// The icon's colour in place of the grey: a profile's.
    var tint: Color?
    /// The site whose icon to show in place of `icon`.
    var site: URL?
    /// The incognito mark in place of `icon`.
    var mark = false
    let title: String
    var shortcut: String?
    /// Opens a submenu to its side: a chevron at its end.
    var submenu = false
    /// Its submenu is out, or the keyboard is on it.
    var lit = false
    /// On, as a switch: a tick at its end.
    var checked = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.incognito) private var incognito
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // Disabled, as a system menu's: the title in the icons' grey and the
        // icons fainter, rather than the whole row faded into the glass.
        let ink = isEnabled ? Palette.ink : Palette.muted
        let muted = isEnabled ? Palette.muted : Palette.muted.opacity(0.5)
        return Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let site {
                        Favicon(site: site, size: 14, plate: false)
                    } else if mark {
                        IncognitoMark(size: 15)
                            .foregroundStyle(muted)
                    } else if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .foregroundStyle(tint ?? muted)
                    }
                }
                .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                }
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink)
                }
                if submenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(muted)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && isEnabled || lit ? incognito ? Palette.incognitoAccent.opacity(0.18) : Palette.wash : .clear)
            )
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .onHover { hovering = $0 }
        // VoiceOver reads it as a system menu's item: its name, whether it
        // is ticked, and that it opens a submenu.
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(checked ? "Checked" : "")
        .accessibilityHint(submenu ? "Opens a submenu" : "")
    }
}

/// The row as drawn above, and nothing more: `.plain` would fade a disabled
/// one again on top of its greys.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 5)
    }
}

/// A tab's right-click menu, in the sidebar and across the top alike, in
/// Chrome's order: another tab, what to do with this one, where the tabs go,
/// then closing. A pinned tab's has no tabs "below" it: those are the list's.
struct TabMenu: View {
    let browser: Browser
    let id: Tab.ID

    var body: some View {
        if let tab = browser.tabs.first(where: { $0.id == id }) {
            let others = browser.others(than: id)
            let after = browser.below(id)
            Button("New Tab", action: browser.newTab)
            Divider()
            if tab.hasPage {
                Button("Reload") { tab.reload() }
                Button("Duplicate Tab") { browser.duplicate(id) }
                // A tab of the list has a name to edit there; a pinned site's tile shows none.
                if Browser.listed(tab) { Button("Rename") { browser.renaming = id } }
                if let site = tab.site {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(site.absoluteString, forType: .string)
                    }
                }
                Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { browser.toggleMute(id) }
                // Incognito keeps nothing pinned, nor bookmarks; a secondary
                // window leaves them to the profile's own.
                if browser.keepsPins, let bookmark = tab.bookmark {
                    Button("Remove Bookmark") { withAnimation(.slide) { browser.removeBookmark(bookmark) } }
                } else if browser.keepsPins {
                    Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { withAnimation(.slide) { browser.setPinned(!tab.isPinned, id) } }
                    AddToBookmarks(browser: browser, id: id)
                }
                if let url = tab.shareable { ShareLink("Share", item: url) }
                Divider()
            }
            MoveTab(browser: browser, id: id)
            Divider()
            TabsLayoutMenu(browser: browser)
            Divider()
            Button("Close Tab") { withAnimation(.slide) { browser.close(id) } }
            Button("Close Other Tabs") { browser.close(others, keeping: id) }
                .disabled(others.isEmpty)
            if !tab.isPinned {
                Button(TabStyle.current == .horizontal ? "Close Tabs to the Right" : "Close Tabs Below") { browser.close(after, keeping: id) }
                    .disabled(after.isEmpty)
            }
        }
    }
}

/// Move to New Window, as in Safari and Chrome: on the next display, if there
/// is one. With other windows open, a menu of them too, each by the tab on
/// screen in it.
private struct MoveTab: View {
    let browser: Browser
    let id: Tab.ID

    var body: some View {
        let windows = Windows.others(of: browser)
        // A window of its own already: nothing would change.
        let alone = !browser.keepsPins && browser.tabs.count == 1
        if windows.isEmpty {
            Button("Move to New Window", action: moveToNewWindow)
                .disabled(alone)
        } else {
            Menu("Move to Window") {
                Button("New Window", action: moveToNewWindow)
                    .disabled(alone)
                Divider()
                ForEach(windows, id: \.self) { target in
                    Button(target.selected.map { $0.title.isEmpty ? "New Tab" : $0.title } ?? "Window") {
                        withAnimation(.slide) { browser.move(id, to: target) }
                        target.window?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
    }

    private func moveToNewWindow() {
        Windows.moveToNewWindow(id, from: browser, on: Windows.nextScreen(after: browser.window))
    }
}

/// Add to Bookmarks: at the end of them, or, once there are folders, in the
/// one picked, each folder under the one it is in.
private struct AddToBookmarks: View {
    let browser: Browser
    let id: Tab.ID

    var body: some View {
        let folders = browser.bookmarks.folders
        if folders.isEmpty {
            Button("Add to Bookmarks") { add(to: nil) }
        } else {
            Menu("Add to Bookmarks") {
                Button("Bookmarks") { add(to: nil) }
                Divider()
                ForEach(folders) { folder in
                    Button(String(repeating: "    ", count: folder.depth) + folder.item.title) { add(to: folder.id) }
                }
            }
        }
    }

    private func add(to folder: Bookmarks.Item.ID?) {
        withAnimation(.slide) { browser.bookmark(id, in: folder) }
    }
}

/// Right-click where there is no tab (the sidebar or the strip around them):
/// another tab, and where the tabs go.
struct TabsMenu: View {
    let browser: Browser

    var body: some View {
        Button("New Tab", action: browser.newTab)
        Divider()
        TabsLayoutMenu(browser: browser)
    }
}

/// Across the top or down the side (Settings › Appearance › Tab style), and
/// the sidebar collapsed, as View › Collapse Tabs (⌘S).
private struct TabsLayoutMenu: View {
    let browser: Browser
    @AppStorage(TabStyle.key) private var style = TabStyle.vertical

    var body: some View {
        Button(style == .horizontal ? "Show Tabs Vertically" : "Show Tabs Horizontally") {
            style = style == .horizontal ? .vertical : .horizontal
        }
        if style == .vertical {
            Button(browser.sidebarOpen ? "Collapse Tabs" : "Show Tabs", action: browser.toggleSidebar)
        }
    }
}
