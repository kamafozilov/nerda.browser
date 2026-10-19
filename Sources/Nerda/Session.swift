import Foundation

/// The tabs as they were left, opened again at the next launch: after a quit,
/// a crash, or the app being rebuilt. Kept in a JSON file, written soon after
/// every change, and at the latest every few seconds.
nonisolated struct Session: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Sendable {
        /// None for the settings and history tabs.
        let url: URL?
        let title: String
        /// WebKit's own record of the page (`interactionState`): its history,
        /// back and forward, and where it was scrolled to.
        let state: Data?
        let zoom: CGFloat
        /// Optional, and left out unless set, so sessions saved before pins still open.
        let pinned: Bool?
        /// A pinned tab's address when pinned (`Tab.home`); optional, as `pinned`.
        let home: URL?
        /// The settings tab, open on this page of them.
        var settings: SettingsPage? = nil
        /// The history tab.
        var history: Bool? = nil
        /// The name the tab was given in place of its page's title.
        var name: String? = nil
        /// The bookmark it is the tab of.
        var bookmark: UUID? = nil
    }

    var tabs: [Tab]
    /// Which of them was on screen.
    var selected: Int?
    var closed: [ClosedTab]? = nil
    /// A secondary window's place, for it to open on the same display.
    var frame: CGRect? = nil

    struct ClosedTab: Codable, Equatable, Sendable, Identifiable {
        var id = UUID()
        let tab: Tab
        let index: Int
        var date = Date.now
    }

    static let file = Edition.folder.appending(path: "session.json")

    /// Whether pinned tabs load as soon as Nerda opens, and it opens on the
    /// tab left on screen. Off, it opens on a new tab and every tab sleeps
    /// until opened: nothing loads that isn't asked for.
    static let loadsPinsKey = "loadsPinnedTabsAtLaunch"
    static var loadsPins: Bool { UserDefaults.standard.object(forKey: loadsPinsKey) as? Bool ?? true }
}

extension Browser {
    /// Opens the tabs saved in `file`, asleep but the one on screen, and from
    /// then on keeps `file` up to date. A file that can't be read (from a
    /// newer version, or cut short) is set aside rather than overwritten.
    /// New tabs aren't saved: they are nowhere. Left on one, or with none to
    /// open, it starts on a new tab, as other browsers do.
    func restore(from file: URL, loadingPins: Bool = Session.loadsPins) {
        restore(tabs.isEmpty ? Session.read(from: file) : nil, from: file, loadingPins: loadingPins)
    }

    /// The same, with `session` already read from `file` (`Session.reading`).
    func restore(_ session: Session?, from file: URL, loadingPins: Bool = Session.loadsPins) {
        sessionFile = file
        defer { if tabs.isEmpty { add(Tab()) } }
        guard tabs.isEmpty, let session else { return }
        if !isPrivate { recentlyClosed = Array((session.closed ?? []).suffix(25)) }
        add(session.tabs.map(Tab.init(restoring:)))
        guard !tabs.isEmpty else { return }
        // A bookmark taken away since (in another window, before a crash): its tab joins the list.
        for tab in tabs where tab.bookmark.map({ bookmarks.item($0) == nil }) == true { tab.bookmark = nil }
        guard loadingPins else { return add(Tab()) }
        // Pinned sites are there at once, as they always are: loaded once the
        // window is up, which making their pages would hold up, and after the
        // tab on screen, one at a time, so they don't all load together with it.
        Task { [weak self] in
            for tab in self?.tabs ?? [] where tab.isPinned {
                try? await Task.sleep(for: Self.pinLoadGap)
                if tab.isAsleep, self?.tabs.contains(where: { $0 === tab }) == true { _ = tab.webView }
            }
        }
        if let index = session.selected, tabs.indices.contains(index) { selectedID = tabs[index].id } else { add(Tab()) }
    }

    /// The tabs now, as they would be saved.
    var session: Session { session(readingEveryPage: true) }

    /// Without `readingEveryPage`, only the page on screen, where scrolling
    /// happens, and those that went somewhere since are read again.
    func session(readingEveryPage: Bool) -> Session {
        var session = Session(tabs: [], closed: recentlyClosed.isEmpty ? nil : recentlyClosed)
        if isSecondary { session.frame = window?.frame }
        for tab in tabs {
            guard let saved = tab.saved(readingPage: readingEveryPage || tab.id == selectedID) else { continue }
            if tab.id == selectedID { session.selected = session.tabs.count }
            session.tabs.append(saved)
        }
        return session
    }

    /// Writes the session now, if it changed since it was last written, and
    /// with `waiting` waits for it: for quitting, when there is no later.
    /// Only reading the pages' state needs the main thread, and only those
    /// that may have changed are read, but when waiting, when every one is.
    /// Whether anything changed is told from the tabs as they are, not from
    /// their encoding: a sleeping tab's state, the bulk of the file, is the
    /// same bytes each time, and encoding them all, every few seconds, took
    /// tens of ms with 100 tabs. What did change is encoded and written
    /// after, off the main thread.
    func saveSession(waiting: Bool = true) {
        pendingSave?.cancel()
        guard let sessionFile else { return }
        let session = session(readingEveryPage: waiting)
        if session != savedSession {
            // Recently closed tabs, with their pages' state most of the
            // session's size, are written only when they change.
            let closedToo = savedSession.map { $0.closed != session.closed } ?? true
            savedSession = session
            Session.writer.async { [weak self] in
                if !Session.write(session, to: sessionFile, closedToo: closedToo) { Task { @MainActor in self?.savedSession = nil } }
            }
        }
        // Changed or not, what is on its way is on disk before this returns.
        if waiting { Session.writer.sync {} }
    }

    /// Writes the session a moment from now, once for a burst of changes.
    func sessionChanged() {
        guard sessionFile != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveSession(waiting: false) }
        }
    }
}

nonisolated extension Session {
    /// Writes one at a time, in the order asked: a save that waits (quitting)
    /// comes after those on their way, never before.
    static let writer = DispatchQueue(label: "dev.nerda.session", qos: .utility)

    /// What `file` holds, or nil for no file, or one that can't be read: that
    /// one is set aside, as it may be from a newer version. One read whole is
    /// copied beside it (`.previous`), the tabs as they were before this run
    /// changed them, should a wrong state be saved over them.
    static func read(from file: URL) -> Session? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard var session = try? JSONDecoder().decode(Session.self, from: data) else {
            setAside(data, beside: file)
            return nil
        }
        try? data.write(to: file.appendingPathExtension("previous"), options: .atomic)
        // Closed tabs have a file of their own; a session saved before that has them inside.
        if let closed = try? Data(contentsOf: closedFile(of: file)),
           let tabs = try? JSONDecoder().decode([ClosedTab].self, from: closed) {
            session.closed = tabs
        }
        return session
    }

    /// Beside the session's, and not `.json`, so no secondary window takes it for one.
    static func closedFile(of file: URL) -> URL { file.appendingPathExtension("closed") }

    /// Starts reading `file` off the main thread, for launch to go on
    /// meanwhile; what it gives waits for the reading to end. The tabs'
    /// pages make it the biggest file read before the window comes up.
    static func reading(_ file: URL) -> () -> Session? {
        let done = DispatchGroup()
        nonisolated(unsafe) var session: Session?
        DispatchQueue.global(qos: .userInteractive).async(group: done) { session = read(from: file) }
        return {
            done.wait()
            return session
        }
    }

    /// A copy of a file that can't be read, dated, beside it; the last few
    /// are kept, so one set aside isn't lost to the next.
    static func setAside(_ data: Data, beside file: URL, at date: Date = .now, keeping: Int = 3) {
        let folder = file.deletingLastPathComponent()
        let name = "session-unreadable-"
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        try? data.write(to: folder.appending(path: name + stamp + ".json"))
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(name) }.sorted()
        for old in copies.dropLast(keeping) { try? FileManager.default.removeItem(at: folder.appending(path: old)) }
    }

    /// False if it couldn't be written, to be tried again. The closed tabs go
    /// in a file of their own, written only `closedToo`.
    static func write(_ session: Session, to file: URL, closedToo: Bool = true) -> Bool {
        // Keys in order, as ever, so the same tabs make the same file.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var open = session
        open.closed = nil
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(open).write(to: file, options: .atomic)
            if closedToo {
                if let closed = session.closed {
                    try encoder.encode(closed).write(to: closedFile(of: file), options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: closedFile(of: file))
                }
            }
            return true
        } catch {
            NSLog("Nerda: couldn't save the session: \(error)")
            return false
        }
    }

    /// A session's files, for a window gone for good.
    static func remove(_ file: URL) {
        for gone in [file, closedFile(of: file), file.appendingPathExtension("previous")] {
            try? FileManager.default.removeItem(at: gone)
        }
    }
}
