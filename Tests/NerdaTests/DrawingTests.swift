import Foundation
import Testing
@testable import Nerda

private let somewhere = URL(string: "https://example.com")!

/// The sidebar looks up each bookmark's tab, and whether a folder has any
/// open, once for all its rows: the same answers as asking row by row.
@MainActor
@Test func openBookmarksAreFoundOnceForAllRows() {
    let browser = Browser()
    browser.bookmarks = Bookmarks()
    let outer = Bookmarks.Item(title: "outer", children: []), inner = Bookmarks.Item(title: "inner", children: [])
    let other = Bookmarks.Item(title: "other", children: [])
    let a = Bookmarks.Item(title: "a", url: somewhere), b = Bookmarks.Item(title: "b", url: somewhere)
    let top = Bookmarks.Item(title: "top", url: somewhere)
    browser.bookmarks.add(outer)
    browser.bookmarks.add(inner, to: outer.id)
    browser.bookmarks.add(a, to: inner.id)
    browser.bookmarks.add(other)
    browser.bookmarks.add(b, to: other.id)
    browser.bookmarks.add(top)

    // Nothing open: no folder has tabs, nor is any tab a bookmark's.
    browser.add(Tab(), inBackground: true)
    #expect(browser.openBookmarks.tabs.isEmpty && browser.openBookmarks.folders.isEmpty)
    #expect(!browser.hasTabs(in: outer.id))

    browser.open(bookmark: a.id)
    browser.open(bookmark: top.id)
    let open = browser.openBookmarks
    #expect(open.tabs[a.id] === browser.tab(of: a.id) && open.tabs[top.id] === browser.tab(of: top.id))
    #expect(open.tabs[b.id] == nil)
    // Both folders `a` is in, however deep, and no other.
    #expect(open.folders == [outer.id, inner.id])
    for folder in [outer, inner, other] {
        #expect(open.folders.contains(folder.id) == browser.hasTabs(in: folder.id))
    }
    #expect(browser.bookmarks.item(a.id)?.title == "a")
    #expect(browser.bookmarks.item(UUID()) == nil)
}

/// ⌘1 to ⌘9 go through the bookmarks' tabs in the bookmarks' order, folders
/// and all, after the pinned tabs and before the list.
@MainActor
@Test func bookmarksTabsTakeTheirTurnInTheirOrder() {
    let previous = UserDefaults.standard.object(forKey: TabStyle.key)
    UserDefaults.standard.set(TabStyle.vertical.rawValue, forKey: TabStyle.key)
    defer { UserDefaults.standard.set(previous, forKey: TabStyle.key) }
    let browser = Browser()
    browser.bookmarks = Bookmarks()
    let folder = Bookmarks.Item(title: "folder", children: [])
    let a = Bookmarks.Item(title: "a", url: somewhere), b = Bookmarks.Item(title: "b", url: somewhere)
    browser.bookmarks.add(folder)
    browser.bookmarks.add(a, to: folder.id)
    browser.bookmarks.add(b)
    let listed = Tab()
    browser.add(listed)
    browser.open(bookmark: b.id)
    browser.open(bookmark: a.id)
    #expect(browser.inTurn.map(\.id) == [browser.tab(of: a.id)?.id, browser.tab(of: b.id)?.id, listed.id])
}
