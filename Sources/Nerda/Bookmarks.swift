import SwiftUI

/// Pages kept to come back to, in folders, and folders in those: down the
/// sidebar between the pinned sites and New Tab, and in the Bookmarks menu.
/// As in Arc, one opens in a tab of its own that stays in its place rather
/// than joining the list; closed, it stays, and opens afresh at its address.
/// Kept in a JSON file, written whole on each change: they change seldom.
@Observable
final class Bookmarks {
    static let shared = Bookmarks()
    static let file = Edition.folder.appending(path: "bookmarks.json")

    /// A page to come back to, or a folder of them (`children` set).
    nonisolated struct Item: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var title: String
        var url: URL?
        var children: [Item]?
        /// A folder, showing what is in it.
        var open: Bool?

        var isFolder: Bool { children != nil }
    }

    /// A line down the sidebar: a bookmark or a folder, how deep in folders
    /// it is, and where: in which folder (nil: none), at what place in it.
    struct Row: Identifiable {
        let item: Item
        let depth: Int
        let folder: Item.ID?
        let index: Int
        var id: Item.ID { item.id }
    }

    private(set) var items: [Item] = [] {
        didSet { save() }
    }
    /// Where they are saved; nil keeps them to this run, as in tests.
    @ObservationIgnored private(set) var file: URL?

    func load(from file: URL) {
        defer { self.file = file }
        guard let data = try? Data(contentsOf: file) else { return }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else {
            // Set aside rather than overwritten: it may be from a newer version.
            try? data.write(to: file.deletingLastPathComponent().appending(path: "bookmarks-unreadable.json"))
            return
        }
        self.items = items
    }

    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: file, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save bookmarks: \(error)")
        }
    }

    /// What the sidebar shows: the top ones, and under each open folder, what is in it.
    var rows: [Row] { Self.rows(of: items, in: nil, depth: 0, all: false) }
    /// Every one, open folders or not, in order.
    var all: [Row] { Self.rows(of: items, in: nil, depth: 0, all: true) }
    /// Every folder, each under the one it is in, for a menu to put a tab in one.
    var folders: [Row] { all.filter(\.item.isFolder) }

    /// Looked for where it is, without laying every one out in rows first:
    /// the sidebar asks for many, on each pass.
    func item(_ id: Item.ID) -> Item? { Self.find(id, in: items) }

    /// Puts `item` in `folder` (nil: at the top), at `index`; past the end is the end.
    func add(_ item: Item, to folder: Item.ID? = nil, at index: Int = .max) {
        var items = items
        Self.insert(item, into: folder, at: index, in: &items)
        self.items = items
    }

    /// Takes one out, a folder with what is in it.
    @discardableResult
    func remove(_ id: Item.ID) -> Item? {
        var items = items
        guard let removed = Self.remove(id, from: &items) else { return nil }
        self.items = items
        return removed
    }

    /// Whether `id` can go into `folder`: not into itself, nor into a folder inside it.
    func canMove(_ id: Item.ID, into folder: Item.ID?) -> Bool {
        guard let folder, let moving = item(id) else { return true }
        return folder != id && !Self.ids(in: moving).contains(folder)
    }

    /// Moves one to `index` in `folder`, the index counted as things are
    /// before it moves, as a drop is aimed.
    func move(_ id: Item.ID, to folder: Item.ID?, at index: Int) {
        guard canMove(id, into: folder), let from = all.first(where: { $0.id == id }) else { return }
        var items = items
        guard let moving = Self.remove(id, from: &items) else { return }
        Self.insert(moving, into: folder, at: from.folder == folder && from.index < index ? index - 1 : index, in: &items)
        self.items = items
    }

    func rename(_ id: Item.ID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        edit(id) { $0.title = title }
    }

    /// A new title or address, for what is given (an extension's chrome.bookmarks.update).
    func update(_ id: Item.ID, title: String?, url: URL?) {
        edit(id) { item in
            if let title { item.title = title }
            if let url, !item.isFolder { item.url = url }
        }
    }

    /// A folder opened, or closed.
    func toggle(_ id: Item.ID) { edit(id) { $0.open = $0.open == true ? nil : true } }

    func open(_ id: Item.ID) { edit(id) { $0.open = true } }

    private func edit(_ id: Item.ID, _ change: (inout Item) -> Void) {
        var items = items
        Self.edit(id, in: &items, change)
        self.items = items
    }

    /// How many pages, in folders or not.
    nonisolated static func pages(in items: [Item]) -> Int {
        items.reduce(0) { $0 + ($1.children.map(pages) ?? 1) }
    }

    /// Its own id, and all those inside it.
    static func ids(in item: Item) -> [Item.ID] {
        [item.id] + (item.children ?? []).flatMap(ids)
    }

    private static func rows(of items: [Item], in folder: Item.ID?, depth: Int, all: Bool) -> [Row] {
        items.enumerated().flatMap { index, item in
            let inside = all || item.open == true ? rows(of: item.children ?? [], in: item.id, depth: depth + 1, all: all) : []
            return [Row(item: item, depth: depth, folder: folder, index: index)] + inside
        }
    }

    private static func find(_ id: Item.ID, in items: [Item]) -> Item? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children, let found = find(id, in: children) { return found }
        }
        return nil
    }

    /// The folders `ids` are in, however deep; whether any of `items` holds one.
    @discardableResult
    static func folders(holding ids: Set<Item.ID>, in items: [Item], into found: inout Set<Item.ID>) -> Bool {
        var holds = false
        for item in items {
            if let children = item.children {
                if folders(holding: ids, in: children, into: &found) {
                    found.insert(item.id)
                    holds = true
                }
            } else if ids.contains(item.id) {
                holds = true
            }
        }
        return holds
    }

    /// Those of `open` in the bookmarks' order, as the sidebar shows them.
    static func inOrder<T>(_ open: [Item.ID: T], in items: [Item], into found: inout [T]) {
        for item in items {
            if let value = open[item.id] { found.append(value) }
            if let children = item.children { inOrder(open, in: children, into: &found) }
        }
    }

    @discardableResult
    private static func edit(_ id: Item.ID, in items: inout [Item], _ change: (inout Item) -> Void) -> Bool {
        for index in items.indices {
            if items[index].id == id {
                change(&items[index])
                return true
            }
            if items[index].children != nil, edit(id, in: &items[index].children!, change) { return true }
        }
        return false
    }

    private static func insert(_ item: Item, into folder: Item.ID?, at index: Int, in items: inout [Item]) {
        guard let folder else { return items.insert(item, at: min(max(index, 0), items.count)) }
        edit(folder, in: &items) { folder in
            let count = folder.children?.count ?? 0
            folder.children?.insert(item, at: min(max(index, 0), count))
        }
    }

    private static func remove(_ id: Item.ID, from items: inout [Item]) -> Item? {
        if let index = items.firstIndex(where: { $0.id == id }) { return items.remove(at: index) }
        for index in items.indices where items[index].children != nil {
            if let removed = remove(id, from: &items[index].children!) { return removed }
        }
        return nil
    }

    /// The bookmarks in the file every browser exports them to (Chrome,
    /// Safari, Firefox, Arc): Netscape's old HTML, folders and all. A folder's
    /// name (`<H3>`) comes just before the list (`<DL>`) of what is in it.
    nonisolated static func parse(html: String) -> [Item] {
        let tag = /<(\/?)(dl|h3|a)\b([^>]*)>([^<]*)/.ignoresCase()
        let href = /href\s*=\s*"([^"]*)"/.ignoresCase()
        var open: [Item] = []
        var name: String?
        var top: [Item] = []
        for match in html.matches(of: tag) {
            let (_, closing, element, attributes, text) = match.output
            switch (element.lowercased(), closing.isEmpty) {
            case ("h3", true):
                name = unescape(text)
            case ("dl", true):
                open.append(Item(title: name ?? "", children: []))
                name = nil
            case ("dl", false):
                guard let folder = open.popLast() else { continue }
                if open.isEmpty { top += folder.children ?? [] } else { open[open.count - 1].children?.append(folder) }
            case ("a", true):
                guard !open.isEmpty, let link = attributes.firstMatch(of: href),
                      let url = URL(string: unescape(link.output.1)),
                      // Not a bookmarklet (javascript:), nor another browser's own pages.
                      ["http", "https", "file"].contains(url.scheme) else { continue }
                let title = unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
                open[open.count - 1].children?.append(Item(title: title.isEmpty ? url.absoluteString : title, url: url))
            default:
                continue
            }
        }
        return top
    }

    nonisolated private static func unescape(_ text: Substring) -> String {
        String(text).replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'").replacing("&amp;", with: "&")
    }
}

/// See `Browser.openBookmarks`.
struct OpenBookmarks {
    /// A bookmark's tab, by the bookmark, while it is open.
    let tabs: [Bookmarks.Item.ID: Tab]
    /// The folders with a bookmark open in them, however deep.
    let folders: Set<Bookmarks.Item.ID>
}

extension Browser {
    /// A bookmark's tab, while it is open.
    func tab(of bookmark: Bookmarks.Item.ID) -> Tab? { tabs.first { $0.bookmark == bookmark } }

    /// A folder's open tabs, those in folders inside it too.
    func tabs(in folder: Bookmarks.Item.ID) -> [Tab] {
        // Mostly none is open: nothing to look for then.
        guard tabs.contains(where: { $0.bookmark != nil }), let item = bookmarks.item(folder) else { return [] }
        let ids = Set(Bookmarks.ids(in: item))
        return tabs.filter { $0.bookmark.map(ids.contains) == true }
    }

    func hasTabs(in folder: Bookmarks.Item.ID) -> Bool { !tabs(in: folder).isEmpty }

    /// Each open bookmark's tab, and the folders they are in: looked up once
    /// for all the sidebar's rows, rather than through every tab and
    /// bookmark again for each row.
    var openBookmarks: OpenBookmarks {
        let open = Dictionary(tabs.compactMap { tab in tab.bookmark.map { ($0, tab) } }) { first, _ in first }
        var folders = Set<Bookmarks.Item.ID>()
        if !open.isEmpty { Bookmarks.folders(holding: Set(open.keys), in: bookmarks.items, into: &folders) }
        return OpenBookmarks(tabs: open, folders: folders)
    }

    /// A folder's open tabs closed; the bookmarks stay.
    func closeTabs(in folder: Bookmarks.Item.ID) {
        for tab in tabs(in: folder) { close(tab.id) }
    }

    /// A bookmark's tab on screen: the one open, or else a new one, at its address.
    func open(bookmark id: Bookmarks.Item.ID) {
        if let tab = tab(of: id) { return select(tab.id) }
        guard let url = bookmarks.item(id)?.url else { return }
        let tab = Tab()
        tab.bookmark = id
        add(tab)
        tab.go(to: url)
    }

    /// A tab kept as a bookmark in `folder` (nil: at the top), at `index`
    /// (past the end: the end), and from then on, that bookmark's tab: out
    /// of the list, or off the tiles, into the bookmarks.
    func bookmark(_ id: Tab.ID, in folder: Bookmarks.Item.ID? = nil, at index: Int = .max) {
        guard !isPrivate, let tab = tabs.first(where: { $0.id == id }), tab.hasPage, tab.bookmark == nil,
              let site = tab.site else { return }
        if tab.isPinned { move(id, pinned: false, to: 0) }
        let item = Bookmarks.Item(title: tab.title, url: site)
        bookmarks.add(item, to: folder, at: index)
        tab.bookmark = item.id
        sessionChanged()
    }

    /// A bookmark kept no more, a folder with all in it. What of it is open
    /// stays open, in the list, at `position` there (see `move`).
    func removeBookmark(_ id: Bookmarks.Item.ID, to position: Int = 0) {
        guard let item = bookmarks.remove(id) else { return }
        let ids = Set(Bookmarks.ids(in: item))
        for tab in tabs where tab.bookmark.map(ids.contains) == true {
            tab.bookmark = nil
            move(tab.id, pinned: false, to: position, among: Self.listed)
        }
        sessionChanged()
    }

    /// A bookmark dragged down among the tabs: a tab there, at `position`,
    /// and no longer a bookmark.
    func moveToTabs(bookmark id: Bookmarks.Item.ID, at position: Int) {
        guard bookmarks.item(id)?.isFolder == false else { return }
        open(bookmark: id)
        removeBookmark(id, to: position)
    }

    /// ⌘D: the tab on screen kept as a bookmark, at the end of them, or, a
    /// bookmark's, kept no more.
    func toggleBookmark() {
        guard let selected else { return }
        withAnimation(.slide) {
            if let bookmark = selected.bookmark { removeBookmark(bookmark) } else { bookmark(selected.id) }
        }
    }

    /// File › Import Bookmarks: a file Chrome, Safari, Firefox or Arc
    /// exported, in a folder of its own at the end.
    func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.message = "Choose the bookmarks file exported from Chrome, Safari, Firefox or Arc."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return Self.tell("Couldn't read the file", "It isn't a text file.")
        }
        let found = Bookmarks.parse(html: text)
        let count = Bookmarks.pages(in: found)
        guard count > 0 else {
            return Self.tell("No bookmarks in the file", "It isn't a bookmarks file exported from a browser.")
        }
        withAnimation(.slide) { bookmarks.add(Bookmarks.Item(title: "Imported", children: found)) }
        Self.tell(count == 1 ? "1 bookmark imported" : "\(count) bookmarks imported",
                  "They are in the Imported folder, at the end of your bookmarks.")
    }
}
