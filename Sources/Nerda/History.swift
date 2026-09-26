import AppKit
import os

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
    /// How long after a change it is written: whatever else changes by then
    /// goes in the same write, and a crash loses no more than that.
    private static let saveDelay: Duration = .seconds(5)

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
    /// Changed since it was last written: switching apps with nothing new
    /// writes nothing.
    @ObservationIgnored private var dirty = false
    /// What the file had, while it is read off the main thread at launch,
    /// until it is taken in (`settle`).
    @ObservationIgnored private var reading: OSAllocatedUnfairLock<Loaded?>?

    /// A page as what is typed is matched against it: its site, and its title
    /// and address with case and accents folded away, as bytes to look through.
    nonisolated private final class Entry: Sendable {
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

    /// Pages as they were read, each made into an entry, and those latest first.
    nonisolated private struct Loaded: Sendable {
        let visits: [URL: Visit]
        let entries: [URL: Entry]
        let index: [Entry]
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
        let made = Self.indexed(visits, reusing: entries)
        entries = made.entries
        built = made.index
        return made.index
    }

    /// Each page as an entry, and all of them latest first.
    nonisolated private static func indexed(_ visits: [URL: Visit], reusing old: [URL: Entry])
        -> (entries: [URL: Entry], index: [Entry]) {
        var entries: [URL: Entry] = [:]
        entries.reserveCapacity(visits.count)
        for visit in visits.values { entries[visit.url] = entry(for: visit, reusing: old[visit.url]) }
        return (entries, entries.values.sorted { $0.visit.last > $1.visit.last })
    }

    /// One page visited again, or renamed, in its place in the index.
    private func reindex(_ visit: Visit) {
        guard var index = built else { return }
        built = nil
        let old = entries[visit.url]
        let entry = Self.entry(for: visit, reusing: old)
        entries[visit.url] = entry
        if let old, let at = Self.place(of: old, in: index) {
            // Only renamed: it stays where it is.
            if old.visit.last == visit.last {
                index[at] = entry
                built = index
                return
            }
            index.remove(at: at)
        }
        index.insert(entry, at: Self.start(of: visit.last, in: index))
        built = index
    }

    /// Where a page is in the index: among those last visited when it was,
    /// found by halving. Going through all 20,000 took ~1 ms, on every
    /// change of a page's title.
    nonisolated private static func place(of entry: Entry, in index: [Entry]) -> Int? {
        index[start(of: entry.visit.last, in: index)...].firstIndex { $0 === entry }
    }

    /// Where the pages last visited at `date` or before begin in the index.
    nonisolated private static func start(of date: Date, in index: [Entry]) -> Int {
        var low = 0, high = index.count
        while low < high {
            let middle = (low + high) / 2
            if index[middle].visit.last > date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Its folded text is kept while its title is the same.
    nonisolated private static func entry(for visit: Visit, reusing old: Entry?) -> Entry {
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

    /// Reads what was saved, and makes the index to look through it, off the
    /// main thread: with 20,000 pages, ~70 ms to read and as long to index. At
    /// launch it doesn't wait: the window comes up meanwhile, and it is taken
    /// in once read.
    func load(from file: URL, waiting: Bool = true) {
        self.file = file
        let read = OSAllocatedUnfairLock<Loaded?>(initialState: nil)
        reading = read
        Self.writer.async(qos: .userInitiated, flags: .enforceQoS) {
            read.withLock { $0 = Self.read(file) }
            DispatchQueue.main.async { self.settle() }
        }
        if waiting { settle() }
    }

    nonisolated private static func read(_ file: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            // Set aside rather than overwritten: it may be from a newer version.
            try? data.write(to: file.deletingLastPathComponent().appending(path: "history-unreadable.json"))
            return nil
        }
        let visits = Dictionary(list.map { ($0.url, $0) }) { first, _ in first }
        let made = indexed(visits, reusing: [:])
        return Loaded(visits: visits, entries: made.entries, index: made.index)
    }

    /// Takes in what `load` read, waiting for the rest of it if need be:
    /// before a save, which would write only this run's pages over it, and
    /// before pages are taken out, which would come back with it. Pages
    /// visited in the meantime are added to what was read.
    func settle() {
        guard let read = reading else { return }
        reading = nil
        Self.writer.sync {}
        guard let loaded = read.withLock({ $0 }) else { return }
        let meanwhile = visits.values
        visits = loaded.visits
        entries = loaded.entries
        built = loaded.index
        for new in meanwhile {
            var visit = new
            if let old = visits[new.url] {
                visit.count += old.count
                visit.last = max(old.last, new.last)
                if new.title.isEmpty { visit.title = old.title }
            }
            visits[new.url] = visit
            reindex(visit)
        }
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
        // Written with the next save, not a save of its own: some pages count
        // in their title ("(3) Inbox", a timer), each tick a rewrite of it all.
        dirty = true
    }

    /// One page taken out, from the history page.
    func remove(_ url: URL) {
        settle()
        guard visits.removeValue(forKey: url) != nil else { return }
        if let old = entries.removeValue(forKey: url), var index = built {
            built = nil
            if let at = Self.place(of: old, in: index) { index.remove(at: at) }
            built = index
        }
        changed()
    }

    /// Pages last visited from then on, for Delete browsing data.
    // ponytail: only a page's last visit is kept, so one visited before and
    // again since goes whole. Keep every visit's date if that matters.
    func remove(since date: Date) {
        settle()
        visits = visits.filter { $0.value.last < date }
        built = nil
        dirty = true
        save(waiting: false)
    }

    func clear() {
        settle()
        visits = [:]
        built = nil
        dirty = true
        save(waiting: false)
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
    /// youtube.com), or with nothing typed, all of them, most used first, the
    /// first `limit` of them. Each as its front page, whichever pages of it
    /// were visited.
    func sites(startingWith text: String, limit: Int = .max, now: Date = .now) -> [Visit] {
        let typed = text.lowercased()
        let prefix = typed.hasPrefix("www.") ? String(typed.dropFirst(4)) : typed
        // Each site added up as its pages go by, each page scored once: a
        // site you use has thousands. Its best page gives its address; its
        // front page, the latest, its title.
        var bySite: [String: (best: Visit, bestScore: Double, score: Double, count: Int, last: Date, front: String?)] = [:]
        for entry in index {
            guard let site = entry.site, site.hasPrefix(prefix) else { continue }
            let score = score(entry.visit, now)
            let front = entry.isFront ? entry.visit.title : nil
            guard var found = bySite[site] else {
                bySite[site] = (entry.visit, score, score, entry.visit.count, entry.visit.last, front)
                continue
            }
            if score > found.bestScore { (found.best, found.bestScore) = (entry.visit, score) }
            found.score += score
            found.count += entry.visit.count
            found.last = max(found.last, entry.visit.last)
            found.front = found.front ?? front
            bySite[site] = found
        }
        return bySite.values.sorted { $0.score > $1.score }.prefix(limit).map { site in
            var root = URLComponents()
            root.scheme = site.best.url.scheme
            root.host = site.best.url.host()
            root.port = site.best.url.port
            root.path = "/"
            return Visit(url: root.url ?? site.best.url, title: site.front ?? "", count: site.count, last: site.last)
        }
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

    /// Pages with each of `words` anywhere in their title or address, case
    /// and accents aside, last visited from `start` through `end`, latest
    /// first, the first `limit` of them: for the history page's search, and
    /// extensions'.
    func pages(containing words: [String], from start: Date = .distantPast, through end: Date = .distantFuture,
               limit: Int = .max) -> [Visit] {
        let words = words.map { Array(Self.fold($0).utf8) }.filter { !$0.isEmpty }
        let index = self.index
        var found: [Visit] = []
        for entry in index[Self.start(of: end, in: index)...] {
            guard entry.visit.last >= start, found.count < limit else { break }
            if words.allSatisfy({ Self.find($0, in: entry.text, anywhere: true) }) { found.append(entry.visit) }
        }
        return found
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

    /// Writes what changed since it was last written, off the main thread:
    /// encoding 20,000 pages takes tens of ms, a hitch in a page being
    /// scrolled. Waiting for it, and any write before it, for quitting, when
    /// there is no later.
    func save(waiting: Bool = true) {
        settle()
        pendingSave?.cancel()
        pendingSave = nil
        guard let file else { return }
        if dirty {
            dirty = false
            trim()
            let visits = visits
            Self.writer.async { Self.write(Array(visits.values), to: file) }
        }
        if waiting { Self.writer.sync {} }
    }

    /// Reads and saves one at a time, in the order asked, off the main thread.
    nonisolated private static let writer = DispatchQueue(label: "dev.nerda.history", qos: .utility)

    nonisolated private static func write(_ visits: [Visit], to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(visits).write(to: file, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save history: \(error)")
        }
    }

    /// Drops what is older than 90 days, and past the limit the oldest: the
    /// index's last pages, as it is latest first, so nothing is sorted again.
    private func trim() {
        let cutoff = Date.now.addingTimeInterval(-Self.keptFor)
        var index = self.index
        let kept = min(Self.start(of: cutoff, in: index), Self.limit)
        guard kept < index.count else { return }
        built = nil
        for entry in index[kept...] {
            visits.removeValue(forKey: entry.visit.url)
            entries.removeValue(forKey: entry.visit.url)
        }
        index.removeSubrange(kept...)
        built = index
    }

    /// Saved a moment from now, once for whatever changes meanwhile (a page
    /// loading and then naming itself), without waiting for the write. Not
    /// put off by each change, so pages coming one after another can't keep
    /// it from ever being written.
    private func changed() {
        dirty = true
        guard file != nil, pendingSave == nil else { return }
        pendingSave = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            save(waiting: false)
        }
    }
}
