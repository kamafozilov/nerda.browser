import SwiftUI

/// The sidebar's bottom-left corner: opens `SidebarMenu`. In an incognito
/// window it wears the incognito mark, as Chrome's profile button does.
struct SidebarMenuButton: View {
    @Binding var shown: Bool
    var incognito = false

    @State private var hovering = false

    var body: some View {
        Button { withAnimation(SidebarMenu.animation) { shown.toggle() } } label: {
            HStack(spacing: 3) {
                if incognito {
                    IncognitoMark(size: 16)
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
        .help(incognito ? "Incognito" : "Menu")
        .accessibilityLabel(incognito ? "Incognito Menu" : "Menu")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// What the app has besides the tabs, on a panel over the sidebar's bottom
/// corner: History opens to its side, as a submenu does, and so does Developer,
/// the page's developer tools; Settings and New Tab
/// with their keys, and an incognito window. Downloads have their own button beside it. Profiles go at its top once there are any.
/// In an incognito window, no History: it isn't kept there.
/// Drawn by SwiftUI rather than as a system menu, so it can look like the rest.
struct SidebarMenu: View {
    let browser: Browser
    /// Under its button at the window's top right (the tabs across the top),
    /// rather than over it in the sidebar's bottom corner.
    var fromTop = false
    let close: () -> Void

    static let width: CGFloat = 240
    static let animation = Animation.snappy(duration: 0.18)

    private enum Submenu { case history, developer }

    /// The submenu out beside its row: the one the pointer last went over.
    @State private var open: Submenu?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !browser.isPrivate {
                    MenuRow(icon: "clock.arrow.circlepath", title: "History", submenu: true, lit: open == .history) {
                        open = .history
                    }
                    .overlay(alignment: fromTop ? .topTrailing : .bottomLeading) { if open == .history { beside(history) } }
                    .onHover { if $0 { open = .history } }
                }

                MenuRow(icon: "gearshape", title: "Settings", shortcut: "⌘,") { run { browser.openSettings() } }
                    .onHover { if $0 { open = nil } }
                MenuRow(icon: "chevron.left.forwardslash.chevron.right", title: "Developer", submenu: true, lit: open == .developer) {
                    open = .developer
                }
                .overlay(alignment: fromTop ? .topTrailing : .bottomLeading) { if open == .developer { beside(developer) } }
                .onHover { if $0 { open = .developer } }
            }
            MenuDivider()
            MenuRow(icon: "plus", title: "New Tab", shortcut: "⌘T") { run(browser.newTab) }
                .onHover { if $0 { open = nil } }
            MenuRow(mark: true, title: "Incognito Window", shortcut: "⇧⌘N") { run { Windows.openIncognito() } }
                .onHover { if $0 { open = nil } }
        }
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .menuPanel()
        // Esc puts it away, as it does a system menu.
        .background {
            Button("Close Menu", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
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

    private var history: some View {
        let visits = History.shared.recent(12)
        return VStack(spacing: 0) {
            if visits.isEmpty {
                Text("No history yet")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
            }
            ForEach(visits, id: \.url) { visit in
                MenuRow(site: visit.url, title: visit.title.isEmpty ? visit.url.absoluteString : visit.title) {
                    run { browser.go(to: visit.url) }
                }
            }
            MenuDivider()
            MenuRow(icon: "clock.arrow.circlepath", title: "Show All History", shortcut: "⌘Y") { run(browser.openHistory) }
            MenuRow(icon: "trash", title: "Clear History…") { run(browser.clearHistory) }
        }
        .frame(width: 300)
    }

    /// For the page on screen; none without one (a new tab, Settings).
    private var developer: some View {
        let tab = browser.selected
        return VStack(spacing: 0) {
            MenuRow(icon: "wrench.and.screwdriver", title: "Developer Tools", shortcut: "⌥⌘I") { run { tab?.inspect(.tools) } }
            MenuRow(icon: "terminal", title: "JavaScript Console", shortcut: "⌥⌘J") { run { tab?.inspect(.console) } }
            MenuRow(icon: "cursorarrow.rays", title: "Inspect Element", shortcut: "⌥⌘C") { run { tab?.inspect(.element) } }
            MenuDivider()
            MenuRow(icon: "iphone", title: "Responsive Design Mode", shortcut: "⌥⌘R",
                    checked: tab?.responsive != nil) { run(browser.toggleResponsive) }
            MenuRow(icon: "doc.plaintext", title: "View Page Source", shortcut: "⌥⌘U") { run(browser.viewSource) }
                .disabled(tab?.site?.scheme == ViewSource.scheme)
            MenuDivider()
            MenuRow(icon: "curlybraces", title: "Disable JavaScript", checked: tab?.javaScriptOff == true) {
                run { tab?.javaScriptOff.toggle() }
            }
            MenuRow(icon: "trash", title: "Clear Site Data") { run { Task { await tab?.clearSiteData() } } }
        }
        .disabled(tab?.hasPage != true)
        .frame(width: 290)
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
    /// The site whose icon to show in place of `icon`.
    var site: URL?
    /// The incognito mark in place of `icon`.
    var mark = false
    let title: String
    var shortcut: String?
    /// Opens a submenu to its side: a chevron at its end.
    var submenu = false
    /// Its submenu is out.
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
                            .foregroundStyle(muted)
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
            let rest = browser.tabs.filter(Browser.listed)
            let others = rest.filter { $0.id != id }
            let after = tab.isPinned ? [] : Array(rest.drop { $0.id != id }.dropFirst())
            Button("New Tab", action: browser.newTab)
            Divider()
            if tab.hasPage {
                Button("Reload") { tab.reload() }
                // Incognito keeps nothing pinned, nor bookmarks.
                if !browser.isPrivate, let bookmark = tab.bookmark {
                    Button("Remove Bookmark") { withAnimation(.slide) { browser.removeBookmark(bookmark) } }
                } else if !browser.isPrivate {
                    Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { withAnimation(.slide) { browser.setPinned(!tab.isPinned, id) } }
                    AddToBookmarks(browser: browser, id: id)
                }
                Divider()
            }
            TabsLayoutMenu(browser: browser)
            Divider()
            Button("Close Tab") { withAnimation(.slide) { browser.close(id) } }
            Button("Close Other Tabs") { close(others) }
                .disabled(others.isEmpty)
            if !tab.isPinned {
                Button(TabStyle.current == .horizontal ? "Close Tabs to the Right" : "Close Tabs Below") { close(after) }
                    .disabled(after.isEmpty)
            }
        }
    }

    /// This tab stays, and comes on screen if the one there was among them.
    private func close(_ tabs: [Tab]) {
        if tabs.contains(where: { $0.id == browser.selectedID }) { browser.select(id) }
        withAnimation(.slide) { tabs.forEach { browser.close($0.id) } }
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
