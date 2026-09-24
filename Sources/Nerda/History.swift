import Foundation

/// Every page visited, to suggest again as you type: once you have been to
/// YouTube, "yo" means YouTube. Kept per address (how often, how lately, what
/// the page was called) in a JSON file, for 90 days.
// ponytail: all in memory, and rewritten whole on each save: fine for tens of
// thousands of pages (a few MB). SQLite if it ever outgrows that.
final class History {
    static let shared = History()
    static let file = Edition.folder.appending(path: "history.json")
    private static let keptFor: TimeInterval = 90 * 24 * 60 * 60
    private static let limit = 20_000
    /// How quickly a visit counts for less: half as much two weeks on.
    private static let halfLife: TimeInterval = 14 * 24 * 60 * 60

    struct Visit: Codable, Equatable {
        let url: URL
        var title: String
        var count: Int
        var last: Date
    }

    /// Where it is saved; nil keeps it to this run, as in tests.
    private(set) var file: URL?
    private(set) var visits: [URL: Visit] = [:]
    private var pendingSave: Task<Void, Never>?

    func load(from file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            // Set aside rather than overwritten: it may be from a newer version.
            try? data.write(to: file.deletingLastPathComponent().appending(path: "history-unreadable.json"))
            return
        }
        visits = Dictionary(list.map { ($0.url, $0) }) { first, _ in first }
    }

    /// A page from the web was opened. Pages on disk, and the like, are not kept.
    func visit(_ url: URL, title: String, at date: Date = .now) {
        guard ["http", "https"].contains(url.scheme) else { return }
        var visit = visits[url] ?? Visit(url: url, title: "", count: 0, last: date)
        visit.count += 1
        visit.last = date
        if !title.isEmpty { visit.title = title }
        visits[url] = visit
        changed()
    }

    /// The page's title came, after the visit, as it does.
    func name(_ url: URL, _ title: String) {
        guard !title.isEmpty, let visit = visits[url], visit.title != title else { return }
        visits[url]?.title = title
        changed()
    }

    func clear() {
        visits = [:]
        save()
    }

    /// The pages visited last, latest first.
    func recent(_ count: Int) -> [Visit] {
        Array(visits.values.sorted { $0.last > $1.last }.prefix(count))
    }

    /// The sites you go to whose name starts with `text` ("yo" for
    /// youtube.com), or with nothing typed, all of them, most used first. Each
    /// as its front page, whichever pages of it were visited.
    func sites(startingWith text: String, now: Date = .now) -> [Visit] {
        let typed = text.lowercased()
        let prefix = typed.hasPrefix("www.") ? String(typed.dropFirst(4)) : typed
        var bySite: [String: [Visit]] = [:]
        for visit in visits.values {
            guard let site = Self.site(of: visit.url), site.hasPrefix(prefix) else { continue }
            bySite[site, default: []].append(visit)
        }
        return bySite.map { site, pages in
            let best = pages.max { score($0, now) < score($1, now) }!
            var root = URLComponents()
            root.scheme = best.url.scheme
            root.host = best.url.host()
            root.port = best.url.port
            root.path = "/"
            let front = pages.first { $0.url.path().isEmpty || $0.url.path() == "/" }
            let visit = Visit(url: root.url ?? best.url, title: front?.title ?? "",
                              count: pages.reduce(0) { $0 + $1.count }, last: pages.map(\.last).max()!)
            return (visit, pages.reduce(0) { $0 + score($1, now) })
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Pages with every word of `text` starting a word of their title or
    /// address, most used first: "swi" finds Swift, "wift" doesn't.
    func pages(matching text: String, now: Date = .now) -> [Visit] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return visits.values
            .filter { visit in
                let haystack = visit.title + " " + visit.url.absoluteString
                return words.allSatisfy { Self.find($0, startingAWordOf: haystack) }
            }
            .sorted { score($0, now) > score($1, now) }
    }

    /// Case and accents aside. Typed with punctuation in it ("swift-book"), anywhere.
    private static func find(_ word: String, startingAWordOf text: String) -> Bool {
        // Most pages don't have it anywhere: that is quick to tell.
        guard text.localizedStandardContains(word) else { return false }
        guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return true }
        return text.split { !$0.isLetter && !$0.isNumber }.contains {
            $0.range(of: word, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A site as it is typed: its host without www., and its port, if any.
    nonisolated static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map { "\(name):\($0)" } ?? name
    }

    /// Visits, counted for less the longer ago the last was.
    private func score(_ visit: Visit, _ now: Date) -> Double {
        Double(visit.count) * pow(0.5, max(0, now.timeIntervalSince(visit.last)) / Self.halfLife)
    }

    /// Writes it now, dropping what is older than 90 days, and past the limit the oldest.
    func save() {
        pendingSave?.cancel()
        guard let file else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.keptFor)
        let kept = visits.values.filter { $0.last > cutoff }.sorted { $0.last > $1.last }.prefix(Self.limit)
        if kept.count != visits.count { visits = Dictionary(kept.map { ($0.url, $0) }) { first, _ in first } }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(kept)).write(to: file, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save history: \(error)")
        }
    }

    /// Saved a moment from now, once for a burst of changes (a page loading
    /// and then naming itself).
    private func changed() {
        guard file != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { save() }
        }
    }
}
