import SwiftUI

/// The column down the left, on glass: pinned sites as tiles at the top, the
/// bookmarks under them, then the tabs, newest first, under the button that
/// opens another, and along the bottom, the app's menu and downloads. Pinned
/// beside the page, or, while collapsed, brought out over it from the window's
/// edge. Tabs and tiles are dragged into another order; a tab dragged onto the
/// tiles is pinned, a tile dragged down among the tabs unpinned. Either
/// dragged onto the bookmarks is kept there; a bookmark dragged down among
/// the tabs is one of them again.
struct Sidebar: View {
    let browser: Browser
    /// Beside the page (true), or floating over it (false).
    let pinned: Bool
    @Binding var downloadsShown: Bool
    /// The menu in the bottom corner (see `SidebarMenu`), drawn over the whole window.
    @Binding var menuShown: Bool
    /// Dragged wider or narrower at its right edge; see `SidebarResizer`.
    @Binding var width: Double

    static let defaultWidth: Double = 256
    static let widths: ClosedRange<Double> = 200...400
    /// As tall as the window's title bar, so the traffic lights sit in its
    /// middle, level with the middle of the address bar below the margin.
    static let topRow = 2 * (BrowserView.margin + AddressBar.height / 2)
    static let rowHeight: CGFloat = 32
    private static let rowGap: CGFloat = 2
    nonisolated static let tileHeight: CGFloat = 40
    nonisolated static let tileGap: CGFloat = 6
    /// How far in each folder's bookmarks sit.
    private static let indent: CGFloat = 16
    /// The room above and below the tabs, over which they fade as they scroll out.
    private static let edge: CGFloat = 6
    private static let listTop = "list-top"
    nonisolated private static let space = "sidebar"

    @State private var dragged: Drag?
    /// Where the pointer is while dragging, in the sidebar's space. Only the
    /// copy under it reads it, so a move redraws that copy, not every row.
    @State private var pointer = Pointer()
    /// Where a tab from the list would go among the tiles, while it is dragged
    /// over them: set only when that changes.
    @State private var gap: Int?
    /// Where what is dragged over the bookmarks would go, while it is.
    @State private var landing: Landing?
    /// A bookmark or folder whose name is being typed: one just made, or Rename.
    @State private var renaming: Bookmarks.Item.ID?
    /// How tall the bookmarks are, for them to take no more room than that.
    @State private var bookmarksHeight: CGFloat = 0
    @State private var layout = Layout()
    /// The tab the pointer is on, and the one whose card shows (`TabPeek`).
    @State private var hovered: Tab.ID?
    @State private var peeked: Peek?

    /// A tab, tile or bookmark being dragged.
    private struct Drag {
        let id: UUID
        /// From the middle of what was taken hold of to the pointer, so the
        /// same spot stays under it.
        let grab: CGSize
        let size: CGSize
    }

    /// Where the tiles and the tabs' rows are, in the sidebar's space, for a
    /// drag to tell what it is over. Out of SwiftUI's sight: the rows move
    /// with every scroll, and nothing needs drawing again for that.
    private final class Layout {
        var tiles = CGRect.zero
        var rows = CGRect.zero
        /// The tabs' list as it shows, whatever it is scrolled to.
        var list = CGRect.zero
        /// The bookmarks: line and all, the line under them, and their rows.
        var bookmarks = CGRect.zero
        var line = CGRect.zero
        var marks = CGRect.zero
    }

    /// Where something dragged over the bookmarks goes: into a folder (at its
    /// end), lit, or between two of them (at `index` in `folder`), where a gap
    /// opens for it. `row` counts the rows showing, what is dragged left out:
    /// the folder's, or where the gap is. None while there are no bookmarks:
    /// where to drop one shows then.
    private struct Landing: Equatable {
        let folder: Bookmarks.Item.ID?
        let index: Int
        var row: Int?
        var depth = 0
        var into = false
    }

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit on this row, and it moves the window, as
            // the title bar under it would. The sidebar's button is on the
            // address bar; out over the page, the sidebar has its own, to keep it.
            ZStack(alignment: .trailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .titleBar()
                #if DEBUG
                DevBadge()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 88)
                #endif
                if !pinned {
                    SidebarToggle(open: false, toggle: browser.toggleSidebar)
                        .padding(.trailing, 10)
                }
            }
            .frame(height: Self.topRow)

            // Incognito tabs go with their window: nothing there to keep pinned.
            if !browser.isPrivate {
                tiles
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.tiles = $0 }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            // Incognito keeps no bookmarks either.
            if !browser.isPrivate {
                bookmarkList
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.bookmarks = $0 }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            // Fixed: always within reach, however far down the tabs go.
            SidebarRow(icon: "plus", title: "New Tab", dimmed: true, action: browser.newTab)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollViewReader { list in
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.rowGap) {
                        ForEach(rest) { tab in
                            // The buttons hold only the id: SwiftUI keeps their actions a
                            // while after the row goes, and a tab held there keeps its page,
                            // playing, after it is closed.
                            let id = tab.id
                            SidebarRow(
                                icon: tab.settings != nil ? "gearshape" : tab.showsHistory ? "clock.arrow.circlepath" : "globe",
                                site: tab.site,
                                loading: tab.isLoading,
                                title: tab.title,
                                selected: id == browser.selectedID,
                                close: { withAnimation(.slide) { browser.close(id) } },
                                // A new tab, or the settings, keeps the name it has.
                                rename: tab.hasPage ? { name in
                                    if let name { browser.rename(id, to: name) }
                                    browser.focusPage()
                                } : nil,
                                press: { browser.select(id) }
                            ) {
                                browser.select(id)
                            }
                            // Its place stays empty while it is dragged: where it will land.
                            .opacity(dragged?.id == id ? 0 : 1)
                            // A sleeping tab's site is connected to on the way to a click
                            // on it. By its id, as the buttons hold it.
                            .onHover { over in
                                if over { hovered = id } else if hovered == id { hovered = nil }
                                guard over, let tab = browser.tabs.first(where: { $0.id == id }), tab.isAsleep,
                                      let site = tab.site else { return }
                                Tab.preconnect(to: site)
                            }
                            .simultaneousGesture(drag(id))
                            .contextMenu { TabMenu(browser: browser, id: id) }
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.rows = $0 }
                    .padding(.horizontal, 8)
                    .padding(.vertical, Self.edge)
                    .background(alignment: .top) { Color.clear.frame(height: 0).id(Self.listTop) }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.list = $0 }
                .scrollIndicators(.never)
                // Only scrolls once the tabs outgrow the sidebar.
                .scrollBounceBehavior(.basedOnSize)
                // Tabs fade out at the list's edges instead of being cut off
                // there, and never scroll up under New Tab.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edge)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edge)
                    }
                }
                // The tab on screen stays in sight: one opened while scrolled
                // down arrives at the top, out of view otherwise. The newest
                // brings the list right back to its top.
                .onChange(of: browser.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.slide) {
                        if id == rest.first?.id {
                            list.scrollTo(Self.listTop, anchor: .top)
                        } else {
                            list.scrollTo(id)
                        }
                    }
                }
            }

            HStack {
                SidebarMenuButton(shown: $menuShown, incognito: browser.isPrivate)
                Spacer()
                DownloadsButton(browser: browser, shown: $downloadsShown)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: width)
        .coordinateSpace(.named(Self.space))
        // Off the tabs: their own menus are the ones that show on them.
        .contextMenu { TabsMenu(browser: browser) }
        .background { background }
        .overlay(alignment: .trailing) { SidebarResizer(width: $width) }
        // What is dragged follows the pointer, over everything in the sidebar.
        // A tab over the tiles turns into one, the size of the gap opened for it.
        .overlay(alignment: .topLeading) {
            if let dragged, let item = browser.bookmarks.item(dragged.id) {
                UnderPointer(pointer: pointer, grab: dragged.grab, size: dragged.size, width: width) {
                    SidebarRow(icon: item.isFolder ? "folder" : "globe", site: item.url, title: item.title, selected: true) {}
                        .frame(width: dragged.size.width, height: dragged.size.height)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                }
                .allowsHitTesting(false)
            } else if let dragged, let tab = browser.tabs.first(where: { $0.id == dragged.id }) {
                // A tab over the tiles turns into one; a tile over the bookmarks, into a row.
                let becomingTile = gap != nil
                let becomingRow = tab.isPinned && landing != nil
                let size = gap.map { TileGrid.frame($0, of: pins.count + 1, in: layout.tiles).size }
                    ?? (becomingRow ? CGSize(width: layout.bookmarks.width, height: Self.rowHeight) : dragged.size)
                UnderPointer(pointer: pointer, grab: becomingTile || becomingRow ? .zero : dragged.grab, size: size, width: width) {
                    Group {
                        if tab.isPinned && !becomingRow || becomingTile {
                            PinnedTile(site: tab.site, loading: false, title: tab.title, selected: true) {}
                        } else {
                            SidebarRow(icon: "globe", site: tab.site, title: tab.title, selected: true) {}
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                }
                .animation(.snappy(duration: 0.2), value: becomingTile)
                .animation(.snappy(duration: 0.2), value: becomingRow)
                .allowsHitTesting(false)
            }
        }
        // The card of the tab the pointer rests on, over the page beside it.
        .overlay(alignment: .topLeading) {
            if dragged == nil, let peeked, let index = rest.firstIndex(where: { $0.id == peeked.id }) {
                // Its middle level with the tab's, however tall it is.
                PeekPlacement(at: CGPoint(x: width + 4, y: rowFrame(index).midY), anchor: .leading, clamping: .vertical) {
                    TabPeek(tab: rest[index], look: peeked.id == browser.selectedID ? nil : peeked.look)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // In and out, faded; from one tab's card to the next, at once.
        .animation(.easeOut(duration: 0.12), value: peeked == nil)
        .peeking(browser.tabs.first { $0.id == hovered }, $peeked, selected: browser.selectedID)
    }

    private var pins: [Tab] { Array(browser.tabs.prefix { $0.isPinned }) }
    private var rest: [Tab] { browser.tabs.filter(Browser.listed) }

    /// Where a tab from the list would go among the tiles, dragged to `point` over them.
    private func gap(for id: Tab.ID, at point: CGPoint) -> Int? {
        guard rest.contains(where: { $0.id == id }), overTiles(point) else { return nil }
        return TileGrid.index(at: point, of: pins.count + 1, in: layout.tiles)
    }

    /// With no tiles yet, where to drag one is always shown, dashed. With
    /// some, a tab dragged over them opens a gap between them where it goes.
    private var tiles: some View {
        let pins = pins, gap = gap
        var items: [Tab.ID?] = pins.map(\.id)
        if pins.isEmpty { items = [nil] } else if let gap { items.insert(nil, at: gap) }
        return TileGrid {
            // One list, whatever row each is in, so a tile keeps its drag moving from one to another.
            ForEach(items, id: \.self) { id in
                if let id {
                    if let tab = browser.tabs.first(where: { $0.id == id }) {
                        PinnedTile(site: tab.site, loading: tab.isLoading, title: tab.title,
                                   selected: id == browser.selectedID,
                                   press: { browser.select(id) }) {
                            browser.select(id)
                        }
                        .opacity(dragged?.id == id ? 0 : 1)
                        .simultaneousGesture(drag(id))
                        // Back to where it was pinned, from wherever it has been since.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { tab.goHome() })
                        .contextMenu { TabMenu(browser: browser, id: id) }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                } else if pins.isEmpty {
                    PinSlot(targeted: gap != nil)
                        .transition(.opacity)
                } else {
                    Color.clear
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: gap)
    }

    /// Dragging a tab or tile, by the id alone (see the rows).
    private func drag(_ id: Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil { dragged = start(id, at: value.startLocation) }
                pointer.at = value.location
                let over = gap(for: id, at: value.location)
                if over != gap { gap = over }
                let into = landing(for: id, at: value.location)
                if into != landing { landing = into }
                reorder(id, at: value.location)
            }
            .onEnded { drop(id, at: $0.location) }
    }

    private func start(_ id: Tab.ID, at point: CGPoint) -> Drag? {
        let pins = pins
        let frame: CGRect
        if let index = pins.firstIndex(where: { $0.id == id }) {
            frame = TileGrid.frame(index, of: pins.count, in: layout.tiles)
        } else if let index = rest.firstIndex(where: { $0.id == id }) {
            frame = rowFrame(index)
        } else {
            return nil
        }
        return Drag(id: id, grab: CGSize(width: point.x - frame.midX, height: point.y - frame.midY),
                    size: frame.size)
    }

    /// As the pointer passes over another tab, or tile, the dragged one takes
    /// its place, and the rest make way.
    private func reorder(_ id: Tab.ID, at point: CGPoint) {
        let pins = pins, rest = rest
        withAnimation(.snappy(duration: 0.2)) {
            if pins.contains(where: { $0.id == id }) {
                // Heading down into the list: unpinned there on drop.
                guard !belowTiles(point) else { return }
                browser.move(id, pinned: true, to: TileGrid.index(at: point, of: pins.count, in: layout.tiles))
            } else if !overTiles(point) {
                guard !overBookmarks(point) else { return }
                browser.move(id, pinned: false, to: rowIndex(at: point.y, of: rest.count), among: Browser.listed)
            }
        }
    }

    /// Onto the tiles, a tab is pinned where it is let go; onto the bookmarks,
    /// either is kept there; a tile let go below them is unpinned there.
    /// Anywhere else, it stays where the drag put it.
    private func drop(_ id: Tab.ID, at point: CGPoint) {
        let gap = gap, landing = landing
        withAnimation(.slide) {
            dragged = nil
            self.gap = nil
            self.landing = nil
            guard let tab = browser.tabs.first(where: { $0.id == id }) else { return }
            if let landing {
                browser.bookmark(id, in: landing.folder, at: landing.index)
            } else if tab.isPinned, overList(point) {
                browser.move(id, pinned: false, to: rowIndex(at: point.y, of: rest.count + 1), among: Browser.listed)
            } else if let gap {
                browser.move(id, pinned: true, to: gap)
            }
        }
    }

    /// The bookmarks, over a line that parts them from the tabs, as Arc's
    /// and Zen's pinned tabs are: a tab dragged above it is kept there, in a
    /// gap that opens where it goes. With none yet, a tab being dragged finds
    /// where to drop it, dashed, as the tiles show theirs. They take the room
    /// they need, and scroll once that is more than the tabs leave them.
    private var bookmarkList: some View {
        let rows = browser.bookmarks.rows
        let dragged = dragged.flatMap { browser.bookmarks.item($0.id) }
        // What is inside a folder dragged goes with it; the folder itself stays,
        // folded to nothing, as its drag is its row's.
        let inside = Set(dragged.map(Bookmarks.ids(in:))?.dropFirst() ?? [])
        let gap = landing.flatMap { $0.into ? nil : $0.row }
        var items: [Bookmarks.Item.ID?] = []
        var shown = 0
        for row in rows where !inside.contains(row.id) {
            if row.id != dragged?.id {
                if shown == gap { items.append(nil) }
                shown += 1
            }
            items.append(row.id)
        }
        if gap == shown { items.append(nil) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return VStack(spacing: 0) {
            if !items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.self) { id in
                            if let id, let row = byID[id] {
                                bookmarkRow(row)
                            } else {
                                Color.clear.frame(height: Self.rowHeight + Self.rowGap)
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) { landingMark.allowsHitTesting(false) }
                    .animation(.snappy(duration: 0.2), value: landing)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.marks = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bookmarksHeight = $0 }
                }
                .frame(maxHeight: bookmarksHeight)
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity)
            }
            Group {
                if rows.isEmpty, bookmarking {
                    PinSlot(targeted: landing != nil, icon: "bookmark", height: Self.rowHeight,
                            tip: "Drag a tab here to bookmark it")
                        .padding(.bottom, 4)
                        .transition(.opacity)
                } else {
                    BookmarksLine()
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.line = $0 }
            .contextMenu { Button("New Folder") { newFolder(in: nil) } }
            .animation(.snappy(duration: 0.2), value: bookmarking)
        }
    }

    /// A tab that could be kept as a bookmark is being dragged.
    private var bookmarking: Bool {
        guard let dragged, let tab = browser.tabs.first(where: { $0.id == dragged.id }) else { return false }
        return tab.hasPage && tab.bookmark == nil
    }

    /// The bookmarks' rows, less what is being dragged of them.
    private var shownRows: [Bookmarks.Row] {
        let rows = browser.bookmarks.rows
        guard let id = dragged?.id, let item = browser.bookmarks.item(id) else { return rows }
        let gone = Set(Bookmarks.ids(in: item))
        return rows.filter { !gone.contains($0.id) }
    }

    /// A bookmark, its site's icon and its own name, open or not: on screen
    /// once clicked, closed by its button, and then only kept. A folder,
    /// opened by a click, and named by Rename, not by a double-click, which
    /// opens and closes it.
    private func bookmarkRow(_ row: Bookmarks.Row) -> some View {
        // By their ids alone, as the tabs' rows.
        let id = row.id, item = row.item
        let tab = browser.tab(of: id)
        let tabID = tab?.id
        return SidebarRow(
            icon: item.isFolder ? "folder" : "globe",
            site: item.isFolder ? nil : tab?.site ?? item.url,
            loading: tab?.isLoading ?? false,
            title: item.title,
            selected: tabID != nil && tabID == browser.selectedID,
            close: tabID.map { tabID in { withAnimation(.slide) { browser.close(tabID) } } },
            rename: { name in
                renaming = nil
                if let name { browser.bookmarks.rename(id, to: name) }
                browser.focusPage()
            },
            renameNow: renaming == id,
            doubleClickRenames: !item.isFolder,
            press: tabID.map { tabID in { browser.select(tabID) } }
        ) {
            if item.isFolder {
                withAnimation(.snappy(duration: 0.2)) { browser.bookmarks.toggle(id) }
            } else {
                browser.open(bookmark: id)
            }
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .padding(.bottom, Self.rowGap)
        // Folded away while dragged, the gap where it goes open instead.
        .frame(height: dragged?.id == id ? 0 : nil, alignment: .top)
        .opacity(dragged?.id == id ? 0 : 1)
        .simultaneousGesture(bookmarkDrag(id))
        .contextMenu { bookmarkMenu(row) }
    }

    @ViewBuilder
    private func bookmarkMenu(_ row: Bookmarks.Row) -> some View {
        let id = row.id
        if row.item.isFolder {
            Button("New Folder") { newFolder(in: id) }
            Button("Rename") { renaming = id }
            Divider()
            Button("Delete Folder") { withAnimation(.slide) { browser.removeBookmark(id) } }
        } else if let url = row.item.url {
            // Its tab gone elsewhere since it was opened: back to the page kept.
            if let tab = browser.tab(of: id), tab.site != url {
                let tabID = tab.id
                Button("Back to Bookmarked Page") { browser.tabs.first { $0.id == tabID }?.go(to: url) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Rename") { renaming = id }
            Button("New Folder") { newFolder(in: row.folder, at: row.index + 1) }
            Divider()
            Button("Remove Bookmark") { withAnimation(.slide) { browser.removeBookmark(id) } }
        }
    }

    /// A folder in `folder` (nil: at the top), open, with its name to type.
    private func newFolder(in folder: Bookmarks.Item.ID?, at index: Int = .max) {
        let item = Bookmarks.Item(title: "New Folder", children: [])
        withAnimation(.snappy(duration: 0.2)) {
            if let folder { browser.bookmarks.open(folder) }
            browser.bookmarks.add(item, to: folder, at: index)
        }
        renaming = item.id
    }

    /// The folder it would go into, lit.
    @ViewBuilder
    private var landingMark: some View {
        if let landing, landing.into, let row = landing.row {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape.fill(Palette.hover)
                .overlay(shape.strokeBorder(Palette.muted.opacity(0.6), lineWidth: 1.5))
                .frame(height: Self.rowHeight)
                .padding(.leading, CGFloat(landing.depth) * Self.indent)
                .offset(y: CGFloat(row) * (Self.rowHeight + Self.rowGap))
        }
    }

    /// Dragging a bookmark or folder, by its id alone.
    private func bookmarkDrag(_ id: Bookmarks.Item.ID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil, let index = browser.bookmarks.rows.firstIndex(where: { $0.id == id }) {
                    let frame = markFrame(index)
                    dragged = Drag(id: id, grab: CGSize(width: value.startLocation.x - frame.midX,
                                                        height: value.startLocation.y - frame.midY),
                                   size: frame.size)
                }
                pointer.at = value.location
                let into = landing(for: id, at: value.location)
                if into != landing { landing = into }
            }
            .onEnded { value in
                let landing = landing
                withAnimation(.slide) {
                    dragged = nil
                    self.landing = nil
                    if let landing {
                        browser.bookmarks.move(id, to: landing.folder, at: landing.index)
                    } else if overList(value.location) {
                        browser.moveToTabs(bookmark: id, at: rowIndex(at: value.location.y, of: rest.count + 1))
                    }
                }
            }
    }

    /// Where a tab, tile or bookmark dragged to `point` would go among the
    /// bookmarks: onto the line under them, at the end; onto a folder's middle, into
    /// it; nearer a row's top or bottom, above or below it. A folder not into
    /// itself; a new tab, or the settings, nowhere: they have no site to keep.
    private func landing(for id: UUID, at point: CGPoint) -> Landing? {
        guard overBookmarks(point) else { return nil }
        if let tab = browser.tabs.first(where: { $0.id == id }), !tab.hasPage || tab.bookmark != nil { return nil }
        let rows = shownRows
        guard !rows.isEmpty, point.y < layout.line.minY else {
            return Landing(folder: nil, index: .max, row: rows.isEmpty ? nil : rows.count)
        }
        let pitch = Self.rowHeight + Self.rowGap
        let y = point.y - layout.marks.minY
        var index = Int((y / pitch).rounded(.down))
        let within = index < 0 ? 0 : (y - CGFloat(index) * pitch) / Self.rowHeight
        // Over the gap open, it stays; past it, the rows sit one further down.
        if let current = self.landing, !current.into, let gap = current.row {
            if index == gap { return current }
            if index > gap { index -= 1 }
        }
        let landing: Landing
        if index >= rows.count {
            landing = Landing(folder: nil, index: .max, row: rows.count)
        } else {
            let row = rows[max(index, 0)]
            if row.item.isFolder, (0.25...0.75).contains(within) {
                landing = Landing(folder: row.id, index: .max, row: index, depth: row.depth, into: true)
            } else if within < 0.5 {
                landing = Landing(folder: row.folder, index: row.index, row: max(index, 0), depth: row.depth)
            } else if row.item.open == true, row.item.children?.isEmpty == false {
                landing = Landing(folder: row.id, index: 0, row: index + 1, depth: row.depth + 1)
            } else {
                landing = Landing(folder: row.folder, index: row.index + 1, row: index + 1, depth: row.depth)
            }
        }
        return browser.bookmarks.canMove(id, into: landing.folder) ? landing : nil
    }

    /// Below `zoneEdge`, down to just under the line.
    private func overBookmarks(_ point: CGPoint) -> Bool {
        !browser.isPrivate && (zoneEdge...layout.bookmarks.maxY + 4).contains(point.y) && (0...width).contains(point.x)
    }

    /// Halfway between the tiles and the bookmarks: a drag above it is over
    /// the tiles, below it over the bookmarks, never both.
    private var zoneEdge: CGFloat {
        browser.isPrivate ? .infinity : (layout.tiles.maxY + layout.bookmarks.minY) / 2
    }

    private func overList(_ point: CGPoint) -> Bool {
        point.y > layout.list.minY && (0...width).contains(point.x)
    }

    private func markFrame(_ index: Int) -> CGRect {
        let marks = layout.marks
        return CGRect(x: marks.minX, y: marks.minY + CGFloat(index) * (Self.rowHeight + Self.rowGap),
                      width: marks.width, height: Self.rowHeight)
    }

    private func overTiles(_ point: CGPoint) -> Bool {
        layout.tiles.insetBy(dx: 0, dy: -8).contains(point) && point.y < zoneEdge
    }
    private func belowTiles(_ point: CGPoint) -> Bool { point.y > layout.tiles.maxY + 8 }

    private func rowFrame(_ index: Int) -> CGRect {
        let rows = layout.rows
        return CGRect(x: rows.minX, y: rows.minY + CGFloat(index) * (Self.rowHeight + Self.rowGap),
                      width: rows.width, height: Self.rowHeight)
    }

    /// The row under `y` of `count`, the first above them all and the last below.
    private func rowIndex(at y: CGFloat, of count: Int) -> Int {
        let row = Int(((y - layout.rows.minY) / (Self.rowHeight + Self.rowGap)).rounded(.down))
        return min(max(row, 0), count - 1)
    }

    /// The system's sidebar glass, pinned or floating alike, so it looks the
    /// same sliding as at rest. Pinned, it is one with the window's glass
    /// around the page; floating, an edge and a shadow lift it off the page.
    private var background: some View {
        SidebarGlass(incognito: browser.isPrivate)
            .overlay(alignment: .trailing) {
                if !pinned { Rectangle().fill(Palette.hairline).frame(width: 1) }
            }
            .shadow(color: .black.opacity(pinned ? 0 : 0.25), radius: 16, x: 4)
    }
}

/// The tiles: three to a row, each row shared out evenly, so one fills the
/// width. A drag finds what it is over by the same sums.
private struct TileGrid: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = CGFloat((subviews.count + 2) / 3)
        return CGSize(width: proposal.width ?? 0, height: max(rows * (Sidebar.tileHeight + Sidebar.tileGap) - Sidebar.tileGap, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let frame = Self.frame(index, of: subviews.count, in: bounds)
            subview.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }

    static func frame(_ index: Int, of count: Int, in bounds: CGRect) -> CGRect {
        let row = index / 3
        let across = CGFloat(min(3, count - row * 3))
        let width = (bounds.width - Sidebar.tileGap * (across - 1)) / across
        return CGRect(x: bounds.minX + CGFloat(index % 3) * (width + Sidebar.tileGap),
                      y: bounds.minY + CGFloat(row) * (Sidebar.tileHeight + Sidebar.tileGap),
                      width: width, height: Sidebar.tileHeight)
    }

    /// The tile under `point` of `count`: the nearest, from outside them.
    static func index(at point: CGPoint, of count: Int, in bounds: CGRect) -> Int {
        let row = min(max(Int(((point.y - bounds.minY) / (Sidebar.tileHeight + Sidebar.tileGap)).rounded(.down)), 0),
                      (count - 1) / 3)
        let across = min(3, count - row * 3)
        let column = Int(((point.x - bounds.minX) / ((bounds.width + Sidebar.tileGap) / CGFloat(across))).rounded(.down))
        return row * 3 + min(max(column, 0), across - 1)
    }
}

/// Where the pointer is while a tab or tile is dragged.
@Observable
final class Pointer {
    var at = CGPoint.zero
}

/// What is dragged, under the pointer: the one view a move of the pointer
/// draws again. Across, kept within the sidebar, as the tabs are.
private struct UnderPointer<Content: View>: View {
    let pointer: Pointer
    let grab: CGSize
    let size: CGSize
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content.position(x: min(max(pointer.at.x - grab.width, size.width / 2 + 8), width - size.width / 2 - 8),
                         y: pointer.at.y - grab.height)
    }
}

#if DEBUG
/// Beside the traffic lights, so a development build is never taken for the
/// Nerda in use.
struct DevBadge: View {
    var body: some View {
        Text(Edition.name.dropFirst("Nerda ".count))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Palette.wash, in: Capsule())
            .allowsHitTesting(false)
    }
}
#endif

/// The frosted desktop behind the window that macOS puts under sidebars
/// (Finder's, Mail's), greyed while the window is in the background as theirs
/// are, and tinted if asked (Settings › Appearance › Transparency); in an
/// incognito window, a plain dark grey instead.
struct SidebarGlass: View {
    var incognito = false

    @AppStorage(Transparency.key) private var transparency = Transparency.transparent

    var body: some View {
        if incognito {
            Palette.incognito
        } else {
            Glass().overlay { if transparency == .tinted { Palette.tint } }
        }
    }
}

/// SwiftUI's own materials only blur what is in the window.
private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The sidebar's right edge: dragged, it sizes the sidebar within
/// `Sidebar.widths`; double-clicked, it puts it back to its default width.
private struct SidebarResizer: View {
    @Binding var width: Double

    /// The width the drag started from. The edge moves with the drag, so
    /// the drag is measured from where it began rather than from the edge.
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            // Half over the page, so the edge is as easy to catch from either side.
            .offset(x: 4)
            // One arrow once a limit is reached, as the system's own edges show.
            .pointerStyle(.frameResize(position: .trailing, directions: directions))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = start ?? width
                        self.start = start
                        width = min(max(start + drag.translation.width, Sidebar.widths.lowerBound), Sidebar.widths.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.slide) { width = Sidebar.defaultWidth } }
            .accessibilityHidden(true)
    }

    private var directions: FrameResizeDirection.Set {
        if width <= Sidebar.widths.lowerBound { return .outward }
        if width >= Sidebar.widths.upperBound { return .inward }
        return .all
    }
}

extension Animation {
    /// For anything that slides into place: tabs arriving and leaving, the
    /// sidebar. Without bounce: a sidebar that overshot its place would pull
    /// away from the window's edge and show a strip of the page there.
    static let slide = Animation.smooth(duration: 0.25)
}

/// Under the bookmarks, the line between them and the tabs, a hairline as
/// Zen's, in a strip tall enough to right-click and drop onto.
private struct BookmarksLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 6)
            .frame(height: 14)
            .contentShape(Rectangle())
    }
}

/// One line of the sidebar: a tab, or the button that opens one.
private struct SidebarRow: View {
    let icon: String
    /// The site whose icon to show in place of `icon`.
    var site: URL?
    /// A spinner in place of the icon, once a load has taken long enough to notice.
    var loading = false
    let title: String
    var selected = false
    /// Greyed, for the New Tab button, so it reads as an action rather than a tab.
    var dimmed = false
    /// Given, the row shows a close button while the pointer is over it.
    var close: (() -> Void)?
    /// Given, a double-click makes the title editable in place: Return or a
    /// click away keeps the new name (nil for Esc, which keeps the old).
    var rename: ((String?) -> Void)?
    /// The title made editable now, as a double-click would.
    var renameNow = false
    var doubleClickRenames = true
    /// Done as the button goes down, not up, as browsers select a tab: a
    /// click's whole press sooner. `action` still does it from the keyboard.
    var press: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false
    @State private var renaming = false
    @Environment(\.incognito) private var incognito

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TabIcon(site: site, loading: loading, fallback: icon)
                    .font(.system(size: 14, weight: dimmed ? .light : .regular))
                    .frame(width: 22)
                if renaming {
                    RenameField(title: title) { name in
                        renaming = false
                        rename?(name)
                    }
                } else {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(dimmed ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            // Room for the close button, so a long title stops short of it.
            .padding(.trailing, close == nil ? 10 : 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Sidebar.rowHeight)
            .background {
                shape
                    .fill(selected ? wash : hovering ? hover : .clear)
                    .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 2, y: 1)
            }
            .overlay { shape.strokeBorder(selected ? rim : .clear) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in press?() })
        // The first click has selected the tab, as a single one does.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if rename != nil, doubleClickRenames { renaming = true } })
        .onChange(of: renameNow, initial: true) { if renameNow, rename != nil { renaming = true } }
        // Over the row rather than inside it, so a click on it closes the tab
        // without also selecting it.
        .overlay(alignment: .trailing) {
            if let close, hovering, !renaming {
                CloseButton(action: close).padding(.trailing, 6)
            }
        }
        // After the overlay, so moving onto the close button still counts as
        // being over the row.
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    // In an incognito window, in its accent.
    private var wash: Color { incognito ? Palette.incognitoAccent.opacity(0.22) : Palette.wash }
    private var hover: Color { incognito ? Palette.incognitoAccent.opacity(0.1) : Palette.hover }
    private var rim: Color { incognito ? Palette.incognitoAccent.opacity(0.35) : Palette.rim }
}

/// A tab's title made editable where it is, all of it selected, so typing
/// replaces it. Return or a click elsewhere keeps what is typed; Esc keeps
/// the title as it was.
struct RenameField: View {
    let title: String
    let done: (String?) -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tab Name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Palette.ink)
            .focused($focused)
            .onSubmit { finish(text) }
            .onKeyPress(.escape) {
                finish(nil)
                return .handled
            }
            .onChange(of: focused) { if !focused { finish(text) } }
            .onAppear {
                text = title
                // A turn later, once the field is in the window (see CommandBar).
                DispatchQueue.main.async { focused = true }
            }
    }

    /// Once: Return also takes the focus away, which would finish it again.
    private func finish(_ name: String?) {
        guard !finished else { return }
        finished = true
        done(name)
    }
}

/// A tab's site icon, bare (see `Favicon`), or a spinner once a load has
/// taken long enough to notice: a quick one would just blink.
struct TabIcon: View {
    let site: URL?
    let loading: Bool
    /// In place of the site's icon, for a row without a site.
    var fallback = "globe"
    var size: CGFloat = 16

    @State private var spinning = false

    var body: some View {
        Group {
            if spinning {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            } else if let site {
                Favicon(site: site, size: size, plate: false)
            } else {
                Image(systemName: fallback)
                    .foregroundStyle(Palette.muted)
            }
        }
        .task(id: loading) {
            guard loading else { return spinning = false }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { spinning = true }
        }
        .animation(.easeOut(duration: 0.15), value: spinning)
    }
}

/// A pinned site: its icon alone, bare, on a tile, its name in a tooltip. The
/// one on screen wears the icon's colours (see `Tint`), as Dia's do: its edge
/// in them, and its glass faintly tinted.
private struct PinnedTile: View {
    let site: URL?
    let loading: Bool
    let title: String
    let selected: Bool
    /// As a tab row's: on the way down.
    var press: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let tint = Favicons.origin(of: site).flatMap { Favicons.shared.tints[$0] }
        let colors = tint?.colors.map { Color(nsColor: $0) } ?? []
        Button(action: action) {
            // Its icon stays while the site loads, once there is one: a
            // pinned site loads at launch, and a slow one (Gmail) would
            // otherwise sit as a spinner for seconds.
            TabIcon(site: site, loading: loading && Favicons.origin(of: site).flatMap { Favicons.shared.images[$0] } == nil,
                    size: 16)
                .frame(maxWidth: .infinity)
                .frame(height: Sidebar.tileHeight)
                .background {
                    // No colour to wear (GitHub's): as dark as the window gets, or as light,
                    // under the mark drawn in the text's colour.
                    if selected, let tint, tint.isGrey {
                        shape.fill(Palette.ground)
                    } else if selected, tint != nil {
                        shape.fill(Color.primary.opacity(0.2))
                            .overlay(shape.fill(LinearGradient(colors: colors.map { $0.opacity(0.14) },
                                                               startPoint: .topLeading, endPoint: .bottomTrailing)))
                            // Lighter in the middle, as glass lit from behind.
                            .overlay(shape.fill(RadialGradient(colors: [.white.opacity(0.06), .clear],
                                                               center: .center, startRadius: 0, endRadius: 40)))
                    } else {
                        shape.fill(Color.primary.opacity(selected ? 0.2 : hovering ? 0.13 : 0.09))
                    }
                }
                // Selected, a bevelled edge, as Dia's: the colour deep, with a
                // lighter line round its outside.
                .overlay {
                    if selected, let tint, !tint.isGrey {
                        let deep = tint.colors.map { Color(nsColor: $0.blended(withFraction: 0.4, of: .black) ?? $0) }
                        let light = tint.colors.map { Color(nsColor: $0.blended(withFraction: 0.35, of: .white) ?? $0).opacity(0.6) }
                        shape.strokeBorder(LinearGradient(colors: deep, startPoint: .leading, endPoint: .trailing), lineWidth: 2.5)
                        shape.strokeBorder(LinearGradient(colors: light, startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                    } else if selected {
                        shape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 3)
                        shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                    } else {
                        // A hairline, lighter than the glass, as its edge catching the light.
                        shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in press?() })
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// While nothing is pinned, where a tab is dragged to pin it: dashed, and lit
/// once the tab is over it. The same, a row high, for the first bookmark.
private struct PinSlot: View {
    let targeted: Bool
    var icon = "pin"
    var height = Sidebar.tileHeight
    var tip = "Drag a tab here to pin it"

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .bold))
                    .offset(x: 6, y: -2)
            }
            .foregroundStyle(targeted ? Palette.ink : Palette.muted)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .help(tip)
            .background(shape.fill(targeted ? Palette.wash : .clear))
            .overlay(shape.strokeBorder(Palette.muted.opacity(targeted ? 0.9 : 0.5),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .animation(.easeOut(duration: 0.14), value: targeted)
    }
}

struct CloseButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Tab")
        .onHover { hovering = $0 }
    }
}

/// Opens and closes the sidebar (⌘S is the View menu's). At the start of the
/// address bar; and on the sidebar itself while it is out over the page, to
/// keep it there.
struct SidebarToggle: View {
    let open: Bool
    let toggle: () -> Void

    @State private var hovering = false
    @State private var showsTip = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
        // The tip waits half a second under the pointer, like the system's own,
        // and goes as soon as the pointer leaves or the button is pressed.
        .task(id: hovering) {
            showsTip = false
            guard hovering else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { showsTip = true }
        }
        .onChange(of: open) { showsTip = false }
        .overlay(alignment: .topLeading) {
            if showsTip {
                Tooltip(title: title, shortcut: "⌘S")
                    .offset(y: 34)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: showsTip)
    }

    private var title: String { open ? "Collapse Tabs" : "Show Tabs" }
}

private struct Tooltip: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
            Text(shortcut)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                )
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.ground)
                .strokeBorder(Palette.hairline)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .fixedSize()
    }
}

#Preview {
    Sidebar(browser: Browser(), pinned: true, downloadsShown: .constant(false), menuShown: .constant(false), width: .constant(Sidebar.defaultWidth))
        .frame(height: 600)
}
