import Foundation

/// The tabs as they were left, opened again at the next launch: after a quit,
/// a crash, or the app being rebuilt. Kept in a JSON file, written soon after
/// every change, and at the latest every few seconds.
struct Session: Codable {
    struct Tab: Codable {
        let url: URL
        let title: String
        /// WebKit's own record of the page (`interactionState`): its history,
        /// back and forward, and where it was scrolled to.
        let state: Data?
        let zoom: CGFloat
        /// Optional, and left out unless set, so sessions saved before pins still open.
        let pinned: Bool?
        /// A pinned tab's address when pinned (`Tab.home`); optional, as `pinned`.
        let home: URL?
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
    func restore(from file: URL) {
        sessionFile = file
        guard tabs.isEmpty, let data = try? Data(contentsOf: file) else { return }
        guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
            try? data.write(to: file.deletingLastPathComponent().appending(path: "session-unreadable.json"))
            return
        }
        for saved in session.tabs.reversed() { add(Tab(restoring: saved), inBackground: true) }
        guard !tabs.isEmpty else { return }
        // Pinned sites are there at once, as they always are.
        for tab in tabs where tab.isPinned { _ = tab.webView }
        let index = session.selected.flatMap { tabs.indices.contains($0) ? $0 : nil } ?? 0
        selectedID = tabs[index].id
        commandBarOpen = false
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

    /// Writes the session now, if it changed since it was last written.
    func saveSession() {
        pendingSave?.cancel()
        // Keys in order, so the same tabs make the same bytes, and nothing is written.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let sessionFile, let data = try? encoder.encode(session), data != savedSession else { return }
        do {
            try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: sessionFile, options: .atomic)
            savedSession = data
        } catch {
            NSLog("Nerda: couldn't save the session: \(error)")
        }
    }

    /// Writes the session a moment from now, once for a burst of changes.
    func sessionChanged() {
        guard sessionFile != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveSession() }
        }
    }
}
