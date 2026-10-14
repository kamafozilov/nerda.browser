import AppKit
import SQLite3
import SwiftUI

/// File › Import From Browser…: the history and bookmarks of another browser
/// on this Mac, read from its own files, as Safari and Chrome import. Chrome,
/// Arc, Brave, Edge and the other Chromium browsers keep history in SQLite
/// and bookmarks in JSON; Firefox keeps both in SQLite. Safari's are behind
/// Full Disk Access, which Nerda doesn't ask for: its bookmarks come in from
/// the file it exports (File › Import Bookmarks…).
nonisolated enum BrowserImport {
    /// A profile of a browser, found on this Mac.
    struct Profile: Identifiable, Hashable, Sendable {
        enum Kind: Sendable { case chromium, firefox }

        let browser: String
        let name: String
        let folder: URL
        let kind: Kind
        let hasHistory: Bool
        let hasBookmarks: Bool
        /// When it was last used, as its history last changed: the one in use comes first.
        let used: Date

        var id: URL { folder }
        var history: URL { folder.appending(path: kind == .chromium ? "History" : "places.sqlite") }
        var bookmarks: URL { kind == .chromium ? folder.appending(path: "Bookmarks") : history }
    }

    /// The Chromium browsers looked for, by their folder in Application Support.
    static let chromium = [
        ("Chrome", "Google/Chrome"), ("Arc", "Arc/User Data"), ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"), ("Vivaldi", "Vivaldi"), ("Opera", "com.operasoftware.Opera"), ("Chromium", "Chromium"),
    ]

    /// Every profile with history or bookmarks to import, browser by browser,
    /// the one used last first in each.
    static func profiles(in support: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support")) -> [Profile] {
        let files = FileManager.default
        var found: [Profile] = []
        for (browser, path) in chromium {
            let root = support.appending(path: path)
            // Names as the browser shows them ("Work"), from its Local State.
            let state = (try? Data(contentsOf: root.appending(path: "Local State")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let names = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
            // Opera keeps its one profile in the browser's own folder.
            let folders = [root] + ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { !["System Profile", "Guest Profile"].contains($0.lastPathComponent) }
            found += folders.compactMap { folder in
                let id = folder.lastPathComponent
                return profile(browser, name: names[id]?["name"] as? String ?? id, folder, .chromium)
            }.sorted { $0.used > $1.used }
        }
        // Firefox names a profile's folder after it: "a1b2c3.default-release".
        let firefox = (try? files.contentsOfDirectory(at: support.appending(path: "Firefox/Profiles"), includingPropertiesForKeys: nil)) ?? []
        found += firefox.compactMap { folder in
            let name = folder.lastPathComponent.split(separator: ".", maxSplits: 1).last.map(String.init) ?? folder.lastPathComponent
            return profile("Firefox", name: name, folder, .firefox)
        }.sorted { $0.used > $1.used }
        return found
    }

    private static func profile(_ browser: String, name: String, _ folder: URL, _ kind: Profile.Kind) -> Profile? {
        let draft = Profile(browser: browser, name: name, folder: folder, kind: kind, hasHistory: false, hasBookmarks: false, used: .distantPast)
        let files = FileManager.default
        let history = files.fileExists(atPath: draft.history.path(percentEncoded: false))
        let bookmarks = files.fileExists(atPath: draft.bookmarks.path(percentEncoded: false))
        guard history || bookmarks else { return nil }
        let used = (try? draft.history.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Profile(browser: browser, name: name.isEmpty ? folder.lastPathComponent : name, folder: folder, kind: kind,
                       hasHistory: history, hasBookmarks: bookmarks, used: used ?? .distantPast)
    }

    // MARK: History

    /// Seconds from 1601, where Chromium counts time from, to 1970.
    private static let chromiumEpoch: Double = 11_644_473_600

    /// The pages of `profile`'s history last visited since `date`, latest
    /// first, at most `limit`: only those from the web, without a name and
    /// password in their address. Nil if its history can't be read.
    static func history(of profile: Profile, since date: Date, limit: Int) -> [History.Visit]? {
        // Chromium counts microseconds from 1601, Firefox from 1970.
        let (sql, start, epoch) = switch profile.kind {
        case .chromium: ("""
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND last_visit_time >= ?1 AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_time DESC LIMIT ?2
            """, (date.timeIntervalSince1970 + chromiumEpoch) * 1_000_000, chromiumEpoch)
        case .firefox: ("""
            SELECT url, title, visit_count, last_visit_date FROM moz_places
            WHERE hidden = 0 AND last_visit_date >= ?1 AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_date DESC LIMIT ?2
            """, date.timeIntervalSince1970 * 1_000_000, 0.0)
        }
        var visits: [History.Visit] = []
        let read = rows(of: profile.history, sql, [Int64(start), Int64(limit)]) { row in
            guard let url = text(row, 0).flatMap({ URL(string: $0) }), ["http", "https"].contains(url.scheme?.lowercased()),
                  let url = History.withoutCredentials(url) else { return }
            let last = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1_000_000 - epoch)
            let count = min(max(Int(sqlite3_column_int64(row, 2)), 1), History.mostVisits)
            visits.append(History.Visit(url: url, title: text(row, 1) ?? "", count: count, last: last))
        }
        return read ? visits : nil
    }

    // MARK: Bookmarks

    /// `profile`'s bookmarks, in their folders, laid out as the browser's own
    /// export lays them out: its bar (or toolbar) as a folder, the rest of
    /// the bookmarks after it. Nil if they can't be read.
    static func bookmarks(of profile: Profile) -> [Bookmarks.Item]? {
        switch profile.kind {
        case .chromium:
            guard let data = try? Data(contentsOf: profile.bookmarks) else { return nil }
            return chromiumBookmarks(data)
        case .firefox:
            return firefoxBookmarks(profile.bookmarks)
        }
    }

    /// Chromium's Bookmarks file: its roots (the bar, Other bookmarks, those
    /// from the phone), each a folder of nodes, a node a folder or a link.
    static func chromiumBookmarks(_ data: Data) -> [Bookmarks.Item]? {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = file["roots"] as? [String: Any] else { return nil }
        func items(_ node: [String: Any]) -> [Bookmarks.Item] {
            (node["children"] as? [[String: Any]] ?? []).compactMap { child in
                let title = child["name"] as? String ?? ""
                if child["type"] as? String == "folder" { return Bookmarks.Item(title: title, children: items(child)) }
                return link(title, child["url"] as? String)
            }
        }
        var found: [Bookmarks.Item] = []
        for key in ["bookmark_bar", "other", "synced"] {
            guard let root = roots[key] as? [String: Any] else { continue }
            let inside = items(root)
            guard !inside.isEmpty else { continue }
            if key == "other" { found += inside } else { found.append(Bookmarks.Item(title: root["name"] as? String ?? "", children: inside)) }
        }
        return found
    }

    /// Firefox's bookmarks, in places.sqlite: each points to its parent, and
    /// to the page (moz_places) it opens.
    static func firefoxBookmarks(_ file: URL) -> [Bookmarks.Item]? {
        // A folder (type 2) or a link (1); separators (3) aren't kept.
        var nodes: [Int64: [(id: Int64, folder: Bool, title: String, url: String?)]] = [:]
        var roots: [String: Int64] = [:]
        let read = rows(of: file, """
            SELECT b.id, b.parent, b.type, b.title, p.url, b.guid FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk WHERE b.type IN (1, 2) ORDER BY b.parent, b.position
            """, []) { row in
            let id = sqlite3_column_int64(row, 0)
            nodes[sqlite3_column_int64(row, 1), default: []].append((id, sqlite3_column_int(row, 2) == 2, text(row, 3) ?? "", text(row, 4)))
            if let guid = text(row, 5) { roots[guid] = id }
        }
        guard read else { return nil }
        func items(_ parent: Int64) -> [Bookmarks.Item] {
            (nodes[parent] ?? []).compactMap { node in
                node.folder ? Bookmarks.Item(title: node.title, children: items(node.id)) : link(node.title, node.url)
            }
        }
        // Its roots' titles are ids ("toolbar"); named here as Firefox shows them. Tags aren't bookmarks.
        var found: [Bookmarks.Item] = []
        for (guid, name) in [("toolbar_____", "Bookmarks Toolbar"), ("menu________", ""),
                             ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            guard let root = roots[guid] else { continue }
            let inside = items(root)
            guard !inside.isEmpty else { continue }
            if name.isEmpty { found += inside } else { found.append(Bookmarks.Item(title: name, children: inside)) }
        }
        return found
    }

    /// A bookmark, of what Nerda opens (as `Bookmarks.parse` keeps): not a
    /// bookmarklet (javascript:), nor another browser's own pages.
    private static func link(_ title: String, _ address: String?) -> Bookmarks.Item? {
        guard let url = address.flatMap({ URL(string: $0) }), ["http", "https", "file"].contains(url.scheme?.lowercased()) else { return nil }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Bookmarks.Item(title: title.isEmpty ? url.absoluteString : title, url: url)
    }

    /// "1,234 pages and 56 bookmarks imported", of what was asked for and
    /// read (nil: not asked for, or not read), and what couldn't be read.
    static func summary(pages: Int?, bookmarks: Int?, failed: [String], from browser: String) -> String {
        let counts = [pages.map { $0 == 1 ? "1 page" : "\($0.formatted()) pages" },
                      bookmarks.map { $0 == 1 ? "1 bookmark" : "\($0.formatted()) bookmarks" }].compactMap(\.self)
        let done = counts.isEmpty ? nil
            : pages ?? 0 > 0 || bookmarks ?? 0 > 0 ? counts.joined(separator: " and ") + " imported" : "Nothing to import"
        let failure = failed.isEmpty ? nil : "Couldn't read the \(failed.joined(separator: " and ")) from \(browser)"
        return [done, failure].compactMap(\.self).joined(separator: ". ")
    }

    // MARK: SQLite

    /// Runs `sql` on a copy of `file`, each row to `row`; false if it can't
    /// be read. A copy, as the browser keeps the file open and locked, with
    /// its write-ahead log or journal beside it, which the copy takes in.
    private static func rows(of file: URL, _ sql: String, _ arguments: [Int64], _ row: (OpaquePointer) -> Void) -> Bool {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appending(path: "Nerda Import \(UUID().uuidString)")
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appending(path: file.lastPathComponent)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: file, to: copy)
            for suffix in ["-wal", "-journal"] {
                try? files.copyItem(at: URL(filePath: file.path(percentEncoded: false) + suffix),
                                    to: URL(filePath: copy.path(percentEncoded: false) + suffix))
            }
        } catch {
            return false
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(copy.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        for (at, value) in arguments.enumerated() { sqlite3_bind_int64(statement, Int32(at + 1), value) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
}

extension Browser {
    /// File › Import From Browser…, as a sheet over the window.
    func importFromBrowser() {
        guard let window, window.attachedSheet == nil else { return }
        let host = NSHostingController(rootView: ImportSheet(profiles: BrowserImport.profiles(), browser: self) { [weak window] in
            if let window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        })
        // Grows to fit as the line saying how it went comes and goes.
        host.sizingOptions = [.preferredContentSize]
        window.beginSheet(NSWindow(contentViewController: host))
    }
}

/// Pick a browser and its profile, and what of it to bring in: Chrome's
/// import dialog, as a sheet. It stays up when done, to say how much came
/// in, or to import another profile.
private struct ImportSheet: View {
    let profiles: [BrowserImport.Profile]
    let browser: Browser
    let close: () -> Void

    @State private var browserName = ""
    @State private var profileID: URL?
    @State private var history = true
    @State private var bookmarks = true
    @State private var task: Task<Void, Never>?
    @State private var result: String?

    private var browsers: [String] { profiles.map(\.browser).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    private var browserProfiles: [BrowserImport.Profile] { profiles.filter { $0.browser == browserName } }
    private var profile: BrowserImport.Profile? { browserProfiles.first { $0.id == profileID } ?? browserProfiles.first }
    private var importing: Bool { task != nil }
    private var takesHistory: Bool { history && profile?.hasHistory == true }
    private var takesBookmarks: Bool { bookmarks && profile?.hasBookmarks == true }
    private var safari: Text {
        Text("Safari's history can't be read. Its bookmarks come in with File › Import Bookmarks…, from the file Safari exports.")
    }

    var body: some View {
        VStack(spacing: 0) {
            if profiles.isEmpty { empty } else { form }
            HStack(spacing: 8) {
                if importing {
                    ProgressView().controlSize(.small).accessibilityLabel("Importing")
                    Text("Importing…").foregroundStyle(.secondary)
                } else if let result {
                    Text(result).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(profiles.isEmpty ? "Close" : result == nil || importing ? "Cancel" : "Done", role: .cancel) {
                    task?.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                if !profiles.isEmpty {
                    Button("Import", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(importing || !(takesHistory || takesBookmarks))
                }
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, profiles.isEmpty ? 0 : 4)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { browserName = browsers.first ?? "" }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Browser", selection: $browserName) {
                    ForEach(browsers, id: \.self) { Text($0) }
                }
                .onChange(of: browserName) { profileID = nil }
                if browserProfiles.count > 1 {
                    Picker("Profile", selection: Binding(get: { profile?.id }, set: { profileID = $0 })) {
                        ForEach(browserProfiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                // Off, and can't be turned on, for a profile without them.
                Toggle("History", isOn: Binding(get: { takesHistory }, set: { history = $0 }))
                    .disabled(profile?.hasHistory != true)
                Toggle("Bookmarks", isOn: Binding(get: { takesBookmarks }, set: { bookmarks = $0 }))
                    .disabled(profile?.hasBookmarks != true)
            } header: {
                Text("Import From Browser")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                safari
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
        .scrollDisabled(true)
        .disabled(importing)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Browsers Found")
                .font(.headline)
            Text("Nerda imports from Chrome, Arc, Brave, Edge, Vivaldi, Opera and Firefox, and none of them is on this Mac.")
            safari
        }
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// Read off the main thread; taken in only if not cancelled meanwhile.
    private func start() {
        guard let profile else { return }
        let history = takesHistory, bookmarks = takesBookmarks
        // Nothing older than Settings › Security & Privacy keeps history for.
        let since = Date.now.addingTimeInterval(-HistoryKeep.current.interval)
        result = nil
        task = Task {
            let read = await Task.detached(priority: .userInitiated) {
                (history ? BrowserImport.history(of: profile, since: since, limit: History.limit) : [],
                 bookmarks ? BrowserImport.bookmarks(of: profile) : [])
            }.value
            guard !Task.isCancelled else { return }
            let pages = if let visits = read.0, !visits.isEmpty { await History.shared.add(visits) } else { 0 }
            let marks = read.1.map(Bookmarks.pages) ?? 0
            if let found = read.1, marks > 0 {
                withAnimation(.slide) { browser.bookmarks.add(Bookmarks.Item(title: "Imported from \(profile.browser)", children: found)) }
            }
            let said = BrowserImport.summary(pages: history && read.0 != nil ? pages : nil,
                                             bookmarks: bookmarks && read.1 != nil ? marks : nil,
                                             failed: (read.0 == nil ? ["history"] : []) + (read.1 == nil ? ["bookmarks"] : []),
                                             from: profile.browser)
            result = said
            task = nil
            AccessibilityNotification.Announcement(said).post()
        }
    }
}
