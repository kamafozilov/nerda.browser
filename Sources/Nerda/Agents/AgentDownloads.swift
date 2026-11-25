import Foundation
import WebKit

/// Downloads from Agent tabs: each goes straight to a folder of its Agent
/// session's under Downloads (the folder chosen in Settings, or the Agent
/// browser's `downloadFolder`), never asked about, and is told to the agent
/// as a notice on the tab it came from (`PageNotices`): by the answer to
/// the action that started it when it is done by then (`AgentPage.act`
/// waits a little for it), else by the next answer about that tab.
@MainActor
enum AgentDownloads {
    /// How long an action's answer waits for a download it started to
    /// finish, to name the file done rather than on its way.
    static let waitAtMost = Duration.seconds(10)

    private final class Entry {
        /// The tab it came from, and the one that opened that tab: a link
        /// opening a tab only to download leaves the opener to be told.
        weak var tab: Tab?
        weak var opener: Tab?
        let folder: URL
        var file: URL?
        var isDone = false

        init(tab: Tab?, opener: Tab?, folder: URL) {
            self.tab = tab
            self.opener = opener
            self.folder = folder
        }

        /// The tab to tell: the one it came from while it is open.
        func told(in browser: Browser?) -> Tab? {
            if let tab, browser?.tabs.contains(where: { $0 === tab }) ?? true { return tab }
            return opener ?? tab
        }

        var name: String { file?.lastPathComponent ?? "a file" }
    }

    private static let entries = NSMapTable<WKDownload, Entry>.weakToStrongObjects()

    /// A download an Agent browser's page started: which tab it is from,
    /// and so which session's folder it goes to.
    static func started(_ download: WKDownload, in browser: Browser) {
        let tab = download.webView.flatMap(browser.tab(for:))
        let opener = tab?.opener.flatMap { id in browser.tabs.first { $0.id == id } }
        let name = [tab, opener].lazy.compactMap { $0 }.compactMap(browser.agentDownloadsFolder).first ?? "Agents"
        entries.setObject(Entry(tab: tab, opener: opener, folder: folder(named: name, in: browser)), forKey: download)
    }

    /// Where a download of an Agent browser goes: its session's folder,
    /// made if need be, under the name the site gives (numbered when taken).
    static func destination(for download: WKDownload?, named name: String, from tab: Tab?, in browser: Browser) -> URL? {
        let entry = download.flatMap { entries.object(forKey: $0) }
        let folder = entry?.folder
            ?? folder(named: tab.flatMap(browser.agentDownloadsFolder) ?? "Agents", in: browser)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            if let tab = entry?.told(in: browser) ?? tab {
                PageNotices.post("a download couldn't be saved: Nerda couldn't make the folder \(folder.path)", on: tab)
            }
            return nil
        }
        let file = Downloads.destination(for: name, in: folder)
        entry?.file = file
        return file
    }

    /// The download is saved: told to its agent with where it is.
    static func finished(_ download: WKDownload, in browser: Browser) {
        guard let entry = entries.object(forKey: download), !entry.isDone else { return }
        entry.isDone = true
        guard let tab = entry.told(in: browser), let file = entry.file else { return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { AgentUploads.size(Int64($0)) }
        PageNotices.post("downloaded \(String(reflecting: entry.name))\(size.map { " (\($0))" } ?? "") to \(file.path)", on: tab)
    }

    /// The download failed or was cancelled: told to its agent.
    static func failed(_ download: WKDownload, _ error: Error, in browser: Browser) {
        guard let entry = entries.object(forKey: download), !entry.isDone else { return }
        entry.isDone = true
        guard let tab = entry.told(in: browser) else { return }
        PageNotices.post("the download of \(String(reflecting: entry.name)) failed: \(error.localizedDescription)", on: tab)
    }

    /// Waits until the downloads from `tab` (or tabs it opened) are done,
    /// or `end`; then answers a notice for each still on its way.
    static func settle(_ tab: Tab, until end: ContinuousClock.Instant) async -> [String] {
        func running() -> [(WKDownload, Entry)] {
            (entries.keyEnumerator().allObjects as? [WKDownload] ?? []).compactMap { download in
                guard let entry = entries.object(forKey: download), !entry.isDone,
                      entry.tab === tab || entry.opener === tab else { return nil }
                return (download, entry)
            }
        }
        while !running().isEmpty, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return running().map { download, entry in
            let so = download.progress.completedUnitCount
            let far = so > 0 ? ", \(AgentUploads.size(so)) so far" : ""
            let to = entry.file.map { " to \($0.path)" } ?? ""
            return "downloading \(String(reflecting: entry.name))\(to)\(far): the next answer about this tab says when it is done"
        }
    }

    private static func folder(named name: String, in browser: Browser) -> URL {
        let safe = name.replacing(/[\/:]/, with: "-").trimmingCharacters(in: .whitespaces.union(["."]))
        return (browser.downloadFolder ?? Downloads.folder).appending(path: safe.isEmpty ? "Agents" : safe, directoryHint: .isDirectory)
    }
}

extension AgentSessions {
    /// The name of the folder under Downloads where the session holding
    /// `tab` saves what it downloads: its title and the start of its id,
    /// such as "Claude 3f2a91c0". nil when no session holds the tab.
    func downloadsFolder(for tab: Tab) -> String? {
        guard let session = all.first(where: { $0.tabs.contains { $0.tab === tab } }) else { return nil }
        let id = session.name.id
        return "\(session.title) \(id.count > 12 ? String(id.prefix(8)) : id)"
    }
}
