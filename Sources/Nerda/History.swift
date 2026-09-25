import AppKit

/// Every page visited, to suggest again as you type: once you have been to
/// YouTube, "yo" means YouTube. Kept per address (how often, how lately, what
/// the page was called) in a JSON file, for 90 days.
// ponytail: all in memory, and rewritten whole on each save: fine for tens of
// thousands of pages (a few MB). SQLite if it ever outgrows that.
@Observable
final class History {
    static let shared = History()
    /// Always empty: what an incognito window's fields suggest from.
    static let empty = History()
    static let file = Edition.folder.appending(path: "history.json")
    private static let keptFor: TimeInterval = 90 * 24 * 60 * 60
    private static let limit = 20_000
    /// How quickly a visit counts for less: half as much two weeks on.
    private static let halfLife: TimeInterval = 14 * 24 * 60 * 60

    nonisolated struct Visit: Codable, Equatable, Sendable {
        let url: URL
        var title: String
        var count: Int
        var last: Date
    }

    /// Where it is saved; nil keeps it to this run, as in tests.
    @ObservationIgnored private(set) var file: URL?
    private(set) var visits: [URL: Visit] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// A page as what is typed is matched against it: its site, and its title
    /// and address with case and accents folded away, as bytes to look through.
    private final class Entry {
        let visit: Visit
        let site: String?
        let text: [UInt8]
        /// The site's front page.
        let isFront: Bool

        init(_ visit: Visit, site: String?, text: [UInt8], isFront: Bool) {
            self.visit = visit
            self.site = site
            self.text = text
            self.isFront = isFront
        }
    }

    /// The last entries made, by address: the next index takes those whose
    /// title is the same, so only new and renamed pages are worked out again.
    @ObservationIgnored private var entries: [URL: Entry] = [:]
    @ObservationIgnored private var built: [Entry]?

    /// Every page, latest first: made once, then kept up to date a page at a
    /// time (`reindex`), not worked out on every key typed. With 20,000
    /// pages, a key costs a few ms, not ~100.
    private var index: [Entry] {
        // Read, so views listing what it finds are told when pages change.
        _ = visits.isEmpty
        if let built { return built }
        var next: [URL: Entry] = [:]
        next.reserveCapacity(visits.count)
        for visit in visits.values { next[visit.url] = Self.entry(for: visit, reusing: entries[visit.url]) }
        entries = next
        let index = next.values.sorted { $0.visit.last > $1.visit.last }
        built = index
        return index
    }

    /// Makes the index ahead of the first key typed (at launch, once idle).
    func prepare() { _ = index }

    /// One page visited again, or renamed, in its place in the index.
    private func reindex(_ visit: Visit) {
        guard var index = built else { return }
        built = nil
        let old = entries[visit.url]
        if let old, let at = index.firstIndex(where: { $0 === old }) { index.remove(at: at) }
        let entry = Self.entry(for: visit, reusing: old)
        entries[visit.url] = entry
        index.insert(entry, at: index.firstIndex { $0.visit.last <= visit.last } ?? index.count)
        built = index
    }

    /// Its folded text is kept while its title is the same.
    private static func entry(for visit: Visit, reusing old: Entry?) -> Entry {
        if let old, old.visit.title == visit.title {
            return old.visit == visit ? old : Entry(visit, site: old.site, text: old.text, isFront: old.isFront)
        }
        let path = visit.url.path()
        return Entry(visit, site: site(of: visit.url), text: Array(fold(visit.title + " " + visit.url.absoluteString).utf8),
                     isFront: path.isEmpty || path == "/")
    }

    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func load(from file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            // Set aside rather than overwritten: it may be from a newer version.
            try? data.write(to: file.deletingLastPathComponent().appending(path: "history-unreadable.json"))
            return
        }
        visits = Dictionary(list.map { ($0.url, $0) }) { first, _ in first }
        built = nil
    }

    /// A page from the web was opened. Pages on disk, and the like, are not kept.
    func visit(_ url: URL, title: String, at date: Date = .now) {
        guard ["http", "https"].contains(url.scheme) else { return }
        var visit = visits[url] ?? Visit(url: url, title: "", count: 0, last: date)
        visit.count += 1
        visit.last = date
        if !title.isEmpty { visit.title = title }
        visits[url] = visit
        reindex(visit)
        changed()
    }

    /// The page's title came, after the visit, as it does.
    func name(_ url: URL, _ title: String) {
        guard !title.isEmpty, var visit = visits[url], visit.title != title else { return }
        visit.title = title
        visits[url] = visit
        reindex(visit)
        changed()
    }

    /// One page taken out, from the history page.
    func remove(_ url: URL) {
        guard visits.removeValue(forKey: url) != nil else { return }
        built = nil
        changed()
    }

    /// Pages last visited from then on, for Delete browsing data.
    // ponytail: only a page's last visit is kept, so one visited before and
    // again since goes whole. Keep every visit's date if that matters.
    func remove(since date: Date) {
        visits = visits.filter { $0.value.last < date }
        built = nil
        save()
    }

    func clear() {
        visits = [:]
        built = nil
        save()
    }

    /// The pages visited last, latest first.
    func recent(_ count: Int) -> [Visit] {
        index.prefix(count).map(\.visit)
    }

    /// The sites visited last, latest first, each once: as the page of it
    /// last seen, to go back to where you were.
    func recentSites(_ count: Int) -> [Visit] {
        var seen = Set<String>()
        var sites: [Visit] = []
        for entry in index {
            guard sites.count < count else { break }
            if seen.insert(entry.site ?? entry.visit.url.absoluteString).inserted { sites.append(entry.visit) }
        }
        return sites
    }

    /// The sites you go to whose name starts with `text` ("yo" for
    /// youtube.com), or with nothing typed, all of them, most used first. Each
    /// as its front page, whichever pages of it were visited.
    func sites(startingWith text: String, now: Date = .now) -> [Visit] {
        let typed = text.lowercased()
        let prefix = typed.hasPrefix("www.") ? String(typed.dropFirst(4)) : typed
        var bySite: [String: [Entry]] = [:]
        for entry in index {
            guard let site = entry.site, site.hasPrefix(prefix) else { continue }
            bySite[site, default: []].append(entry)
        }
        return bySite.map { site, pages in
            // Each page scored once: a site you use has thousands.
            let scores = pages.map { score($0.visit, now) }
            let best = pages[scores.indices.max { scores[$0] < scores[$1] }!].visit
            var root = URLComponents()
            root.scheme = best.url.scheme
            root.host = best.url.host()
            root.port = best.url.port
            root.path = "/"
            let front = pages.first(where: \.isFront)?.visit
            let visit = Visit(url: root.url ?? best.url, title: front?.title ?? "",
                              count: pages.reduce(0) { $0 + $1.visit.count }, last: pages.map(\.visit.last).max()!)
            return (visit, scores.reduce(0, +))
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Pages with every word of `text` starting a word of their title or
    /// address, most used first, the first `limit` of them: "swi" finds
    /// Swift, "wift" doesn't.
    func pages(matching text: String, limit: Int = .max, now: Date = .now) -> [Visit] {
        // Typed with punctuation in it ("swift-book"), a word is found anywhere.
        let words = Self.fold(text).split(separator: " ").map {
            (bytes: Array($0.utf8), anywhere: !$0.allSatisfy { $0.isLetter || $0.isNumber })
        }
        guard !words.isEmpty else { return [] }
        // The best `limit` kept in order as they are found, rather than all sorted.
        // ponytail: insertion, O(pages × limit); fine for the few rows asked for.
        var best: [(visit: Visit, score: Double)] = []
        for entry in index where words.allSatisfy({ Self.find($0.bytes, in: entry.text, anywhere: $0.anywhere) }) {
            let score = score(entry.visit, now)
            guard best.count < limit || score > best[best.count - 1].score else { continue }
            best.insert((entry.visit, score), at: best.firstIndex { $0.score < score } ?? best.count)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.visit)
    }

    /// Whether `word` is in `text` (both folded) where a word of it starts,
    /// or `anywhere`. Past ASCII every byte counts as part of a word, as the
    /// letters it spells mostly are.
    nonisolated private static func find(_ word: [UInt8], in text: [UInt8], anywhere: Bool) -> Bool {
        guard let first = word.first, word.count <= text.count else { return false }
        var at = 0
        while at <= text.count - word.count {
            if text[at] == first, anywhere || at == 0 || !isWordByte(text[at - 1]),
               text[at..<(at + word.count)].elementsEqual(word) {
                return true
            }
            at += 1
        }
        return false
    }

    nonisolated private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
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

    /// Writes it now, and waits for it: for quitting, when there is no later.
    func save() {
        pendingSave?.cancel()
        guard let file else { return }
        let kept = kept()
        Self.writer.sync { Self.write(kept, to: file) }
    }

    /// Saves one at a time, in the order asked, off the main thread: encoding
    /// 20,000 pages takes tens of ms, a hitch in a page being scrolled.
    nonisolated private static let writer = DispatchQueue(label: "dev.nerda.history", qos: .utility)

    nonisolated private static func write(_ visits: [Visit], to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(visits).write(to: file, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save history: \(error)")
        }
    }

    /// What is kept, dropping what is older than 90 days, and past the limit
    /// the oldest. Sorted only when there is something to drop.
    private func kept() -> [Visit] {
        let cutoff = Date.now.addingTimeInterval(-Self.keptFor)
        guard visits.count > Self.limit || visits.values.contains(where: { $0.last <= cutoff }) else {
            return Array(visits.values)
        }
        let kept = Array(visits.values.filter { $0.last > cutoff }.sorted { $0.last > $1.last }.prefix(Self.limit))
        visits = Dictionary(kept.map { ($0.url, $0) }) { first, _ in first }
        built = nil
        return kept
    }

    /// Saved a moment from now, once for a burst of changes (a page loading
    /// and then naming itself), without waiting for the write.
    private func changed() {
        guard let file else { return }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let kept = kept()
            Self.writer.async { Self.write(kept, to: file) }
        }
    }
}
