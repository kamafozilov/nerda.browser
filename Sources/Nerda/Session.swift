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

    static let file = Edition.folder.appending(path: "session.json")
}

extension Browser {
    /// Opens the tabs saved in `file`, asleep but the one on screen, and from
    /// then on keeps `file` up to date. A file that can't be read (from a
    /// newer version, or cut short) is set aside rather than overwritten.
    /// New tabs aren't saved: they are nowhere. Left on one, or with none to
    /// open, it starts on a new tab, as other browsers do.
    func restore(from file: URL) {
        sessionFile = file
        defer { if tabs.isEmpty { add(Tab()) } }
        guard tabs.isEmpty, let data = try? Data(contentsOf: file) else { return }
        guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
            try? data.write(to: file.deletingLastPathComponent().appending(path: "session-unreadable.json"))
            return
        }
        add(session.tabs.map(Tab.init(restoring:)))
        guard !tabs.isEmpty else { return }
        // A bookmark taken away since (in another window, before a crash): its tab joins the list.
        for tab in tabs where tab.bookmark.map({ bookmarks.item($0) == nil }) == true { tab.bookmark = nil }
        // Pinned sites are there at once, as they always are: loaded as soon
        // as the window is up, which making their pages would hold up.
        DispatchQueue.main.async { [weak self] in
            for tab in self?.tabs ?? [] where tab.isPinned { _ = tab.webView }
        }
        if let index = session.selected, tabs.indices.contains(index) { selectedID = tabs[index].id } else { add(Tab()) }
    }

    /// The tabs now, as they would be saved.
    var session: Session {
        var session = Session(tabs: [])
        for tab in tabs {
            guard let saved = tab.saved else { continue }
            if tab.id == selectedID { session.selected = session.tabs.count }
            session.tabs.append(saved)
        }
        return session
    }

    /// Writes the session now, if it changed since it was last written, and
    /// waits for it: for quitting, when there is no later.
    func saveSession() {
        saveSession(waiting: true)
    }

    /// Only reading the pages' state needs the main thread. Whether anything
    /// changed is told from the tabs as they are, not from their encoding: a
    /// sleeping tab's state, the bulk of the file, is the same bytes each time,
    /// and encoding them all, every few seconds, took tens of ms with 100 tabs.
    /// What did change is encoded and written after, off the main thread.
    func saveSession(waiting: Bool) {
        pendingSave?.cancel()
        guard let sessionFile else { return }
        let session = session
        if session != savedSession {
            savedSession = session
            Session.writer.async { [weak self] in
                if !Session.write(session, to: sessionFile) { Task { @MainActor in self?.savedSession = nil } }
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

    /// False if it couldn't be written, to be tried again.
    static func write(_ session: Session, to file: URL) -> Bool {
        // Keys in order, as ever, so the same tabs make the same file.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(session).write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("Nerda: couldn't save the session: \(error)")
            return false
        }
    }
}
