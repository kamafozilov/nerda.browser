import Foundation
import SQLite3
import Testing
@testable import Nerda

private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A database made from `sql`, left open (as the browser keeps it) until closed.
private func database(_ file: URL, _ sql: String) throws -> OpaquePointer {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var opened: OpaquePointer?
    #expect(sqlite3_open(file.path(percentEncoded: false), &opened) == SQLITE_OK)
    let db = try #require(opened)
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
    return db
}

private func profile(_ folder: URL, _ kind: BrowserImport.Profile.Kind) -> BrowserImport.Profile {
    BrowserImport.Profile(browser: "Test", name: "Test", folder: folder, kind: kind, hasHistory: true, hasBookmarks: true, used: .now)
}

/// Chromium counts microseconds from 1601; only the web's pages since the
/// date asked come in, without a name and password in their address.
@Test func chromiumHistoryIsReadFromItsDatabase() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let since = Date.now.addingTimeInterval(-30 * 86400)
    let time = { (date: Date) in Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }
    let recent = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down) - 3600)
    let db = try database(root.appending(path: "History"), """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
            typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
        INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES
            ('https://example.com/', 'Example', 7, \(time(recent))),
            ('https://me:secret@example.org/', 'Signed in', 2, \(time(recent))),
            ('file:///Users/me/notes.html', 'Notes', 3, \(time(recent))),
            ('chrome://settings/', 'Settings', 3, \(time(recent))),
            ('https://old.example/', 'Old', 3, \(time(since.addingTimeInterval(-86400))));
        INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES ('https://ads.example/frame', '', 1, \(time(recent)), 1);
        """)
    sqlite3_close(db)

    let visits = try #require(BrowserImport.history(of: profile(root, .chromium), since: since, limit: 100))
    #expect(Set(visits.map(\.url.absoluteString)) == ["https://example.com/", "https://example.org/"])
    let example = try #require(visits.first { $0.url.host() == "example.com" })
    #expect(example.title == "Example" && example.count == 7)
    #expect(abs(example.last.timeIntervalSince(recent)) < 0.001)
}

/// Firefox's history and bookmarks, from a places.sqlite still open, its
/// latest changes only in its write-ahead log, as while Firefox runs.
@Test func firefoxHistoryAndBookmarksAreReadFromAnOpenDatabase() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let recent = Int64(Date.now.addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
    let db = try database(root.appending(path: "places.sqlite"), """
        PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0,
            hidden INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER);
        CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
            position INTEGER, title LONGVARCHAR, guid TEXT);
        INSERT INTO moz_places VALUES (1, 'https://www.mozilla.org/', 'Mozilla', 4, 0, \(recent)),
            (2, 'https://developer.mozilla.org/', 'MDN', 0, 0, NULL), (3, 'javascript:alert(1)', 'Bookmarklet', 0, 0, NULL);
        INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________'),
            (2, 2, NULL, 1, 0, 'menu', 'menu________'), (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____'),
            (4, 2, NULL, 1, 2, 'tags', 'tags________'), (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____'),
            (6, 1, 1, 3, 0, 'Mozilla', 'a'), (7, 2, NULL, 3, 1, 'Docs', 'b'), (8, 1, 2, 7, 0, 'MDN', 'c'),
            (9, 3, NULL, 3, 2, '', 'd'), (10, 1, 3, 3, 3, 'Bookmarklet', 'e'), (11, 1, 1, 2, 0, 'In the menu', 'f'),
            (12, 2, NULL, 4, 0, 'a tag', 'g');
        """)
    defer { sqlite3_close(db) }
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "places.sqlite-wal").path(percentEncoded: false)))

    let visits = try #require(BrowserImport.history(of: profile(root, .firefox), since: .now.addingTimeInterval(-86400), limit: 100))
    #expect(visits.map(\.title) == ["Mozilla"])
    #expect(visits.first?.count == 4)

    let bookmarks = try #require(BrowserImport.bookmarks(of: profile(root, .firefox)))
    #expect(bookmarks.map(\.title) == ["Bookmarks Toolbar", "In the menu"])
    #expect(bookmarks[0].children?.map(\.title) == ["Mozilla", "Docs"])
    #expect(bookmarks[0].children?[1].children?.first?.url == URL(string: "https://developer.mozilla.org/"))
}

/// Chromium's Bookmarks file: its bar as a folder, Other bookmarks after it,
/// folders kept, its own pages and bookmarklets left out.
@Test func chromiumBookmarksKeepTheirFolders() throws {
    let json = """
        {"roots": {
          "bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
            {"name": "Swift", "type": "url", "url": "https://swift.org/"},
            {"name": "Work", "type": "folder", "children": [{"name": "", "type": "url", "url": "https://github.com/"}]},
            {"name": "Flags", "type": "url", "url": "chrome://flags/"}]},
          "other": {"name": "Other bookmarks", "type": "folder", "children": [
            {"name": "Apple", "type": "url", "url": "https://www.apple.com/"},
            {"name": "Bookmarklet", "type": "url", "url": "javascript:void(0)"}]},
          "synced": {"name": "Mobile bookmarks", "type": "folder", "children": []}}}
        """
    let items = try #require(BrowserImport.chromiumBookmarks(Data(json.utf8)))
    #expect(items.map(\.title) == ["Bookmarks bar", "Apple"])
    #expect(items[0].children?.map(\.title) == ["Swift", "Work"])
    #expect(items[0].children?[1].children?.first?.title == "https://github.com/")
    #expect(Bookmarks.pages(in: items) == 3)
}

/// Each profile with something to import, named as its browser names it.
@Test func profilesAreFoundWithTheirNames() throws {
    let support = try folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let chrome = support.appending(path: "Google/Chrome")
    let files = FileManager.default
    for path in ["Default", "Profile 1", "System Profile", "Empty"] {
        try files.createDirectory(at: chrome.appending(path: path), withIntermediateDirectories: true)
    }
    try Data().write(to: chrome.appending(path: "Default/History"))
    try Data().write(to: chrome.appending(path: "Profile 1/Bookmarks"))
    try Data().write(to: chrome.appending(path: "System Profile/History"))
    try Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}}}}"#.utf8)
        .write(to: chrome.appending(path: "Local State"))
    let firefox = support.appending(path: "Firefox/Profiles/a1b2c3.default-release")
    try files.createDirectory(at: firefox, withIntermediateDirectories: true)
    try Data().write(to: firefox.appending(path: "places.sqlite"))

    let found = BrowserImport.profiles(in: support)
    #expect(Set(found.map { "\($0.browser): \($0.name)" }) == ["Chrome: Personal", "Chrome: Work", "Firefox: default-release"])
    let work = try #require(found.first { $0.name == "Work" })
    #expect(!work.hasHistory && work.hasBookmarks)
}

/// A page Nerda has already joins the one imported: the larger count, so
/// importing the same browser again counts nothing twice, and the later
/// date kept.
@MainActor
@Test func importedHistoryMergesIntoNerdas() async throws {
    let history = History()
    let page = URL(string: "https://example.com/")!
    let earlier = Date.now.addingTimeInterval(-3600)
    history.visit(page, title: "Example", at: earlier)
    let imported = [
        History.Visit(url: page, title: "Example Domain", count: History.mostVisits, last: earlier.addingTimeInterval(-60)),
        History.Visit(url: URL(string: "https://swift.org/")!, title: "Swift", count: 3, last: earlier),
    ]
    #expect(await history.add(imported) == 2)
    let merged = try #require(history.visits[page])
    #expect(merged.count == History.mostVisits)
    #expect(merged.last == earlier && merged.title == "Example")
    #expect(history.pages(matching: "swift").first?.count == 3)
    #expect(await history.add(imported) == 2)
    #expect(history.pages(matching: "swift").first?.count == 3)
}

/// What came in, with the number as the Mac writes it ("1,234" in English).
@Test func theResultSaysWhatCameIn() {
    #expect(BrowserImport.summary(pages: 1234, bookmarks: 56, failed: [], from: "Chrome") == "\(1234.formatted()) pages and 56 bookmarks imported")
    #expect(BrowserImport.summary(pages: 1, bookmarks: nil, failed: [], from: "Chrome") == "1 page imported")
    #expect(BrowserImport.summary(pages: 0, bookmarks: 0, failed: [], from: "Chrome") == "Nothing to import")
    #expect(BrowserImport.summary(pages: nil, bookmarks: 2, failed: ["history"], from: "Arc")
        == "2 bookmarks imported. Couldn't read the history from Arc")
}
