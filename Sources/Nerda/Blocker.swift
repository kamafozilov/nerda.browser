import Foundation
import Observation
import WebKit

/// Ads and trackers, stopped where WebKit loads things (decisions #8), so a
/// page never spends time, memory or battery on them. The lists chosen in
/// Settings (EasyList and EasyPrivacy until others are) are fetched, and
/// again every few days, turned into WebKit's content rules (`ContentRules`)
/// and compiled once per change. WebKit keeps what it compiled: a launch
/// only looks it up. Until there is a list, pages load as they are.
@MainActor
@Observable
final class Blocker {
    static let shared = Blocker()

    /// How long a list is used before it is fetched again.
    private static let refreshAfter: TimeInterval = 4 * 24 * 60 * 60
    // Version the compiled artifact too: unsafe rules from an older converter
    // must never be installed while an update is pending or the Mac is offline.
    // Compiled in parts, each under WebKit's 150,000 rules: "blocklist-v4-0", …
    nonisolated private static let prefix = "blocklist-v4-"
    /// What came before parts, used until they are there.
    nonisolated private static let previous = "blocklist-v3"
    private static let fetchedKey = "blocklist-v3-fetched"
    private static let chosenKey = "filterLists"
    private static let addedKey = "addedFilterLists"

    var isEnabled = UserDefaults.standard.object(forKey: "blockAdsAndTrackers") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "blockAdsAndTrackers")
            for controller in controllers.allObjects {
                rules.forEach(controller.remove)
                if isEnabled { rules.forEach(controller.add) }
            }
        }
    }

    private(set) var rules: [WKContentRuleList] = []
    /// The lists blocked with, by address.
    private(set) var chosen = UserDefaults.standard.stringArray(forKey: Blocker.chosenKey)?.compactMap(URL.init(string:))
        ?? FilterList.catalog[0].lists.prefix(2).map(\.url)
    /// Lists added by their address, chosen or not.
    private(set) var added = UserDefaults.standard.data(forKey: Blocker.addedKey)
        .flatMap { try? JSONDecoder().decode([FilterList].self, from: $0) } ?? []
    /// When the lists in use were fetched, for Settings › Security & Privacy.
    private(set) var updated = UserDefaults.standard.object(forKey: Blocker.fetchedKey) as? Date
    private(set) var refreshing = false
    /// The last fetch didn't work out, all or some of it: what was there before stays in use.
    private(set) var failed = false
    /// Asked for while refreshing: another round after this one, fetching or not.
    private var again: Bool?
    /// Every page's controller, given the rules as they come, and each new list.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var started = false
    private var settled = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var timer: Timer?

    /// Takes the rules compiled last time, then fetches the lists if they are due.
    func start() {
        // Only as Nerda: run from tests, the helper would be the test runner again.
        guard !started, Bundle.main.bundleIdentifier?.hasPrefix("dev.nerda.browser") == true else { return }
        started = true
        Task {
            let parts = await Self.compiled()
            if !parts.isEmpty {
                use(parts)
            } else if let old = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: Self.previous) {
                use([old])
            }
            if rules.isEmpty || isDue { await refresh(fetch: true) }
            settled = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
        // A Mac left on for days still gets new lists.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDue else { return }
                Task { await self.refresh(fetch: true) }
            }
        }
        timer?.tolerance = 60 * 60
    }

    /// A page's controller: it blocks with the rules from now on, and each list after.
    func install(in controller: WKUserContentController) {
        controllers.add(controller)
        if isEnabled { rules.forEach(controller.add) }
    }

    /// Update now, in Settings: the lists fetched again, due or not.
    func update() {
        Task { await refresh(fetch: true) }
    }

    func isChosen(_ list: FilterList) -> Bool { chosen.contains(list.url) }

    /// A list ticked or unticked in Settings: the rules made again, fetching
    /// only a list not fetched before.
    func toggle(_ list: FilterList) {
        if isChosen(list) { chosen.removeAll { $0 == list.url } } else { chosen.append(list.url) }
        changed()
    }

    /// A list of one's own, by its address, blocked with from now on.
    func add(_ url: URL) {
        guard !chosen.contains(url) else { return }
        if !added.contains(where: { $0.url == url }) { added.append(FilterList(title: FilterList.name(of: url), url: url)) }
        chosen.append(url)
        changed()
    }

    func remove(_ list: FilterList) {
        added.removeAll { $0 == list }
        chosen.removeAll { $0 == list.url }
        changed()
    }

    private func changed() {
        UserDefaults.standard.set(chosen.map(\.absoluteString), forKey: Self.chosenKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(added), forKey: Self.addedKey)
        Task { await refresh(fetch: false) }
    }

    /// Once the rules are in, or couldn't be had this time (Nerda Bench times pages with them).
    func ready() async {
        guard started, !settled else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private var isDue: Bool {
        guard let fetched = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date else { return true }
        return Date.now.timeIntervalSince(fetched) > Self.refreshAfter
    }

    /// The chosen lists, fetched (all of them, or only those not fetched
    /// before) and compiled by Nerda run again as a process of its own
    /// (`compileAndExit`): the ~300 MB it takes goes when it does, rather than
    /// staying with Nerda. A list that can't be had is used as last fetched,
    /// and tried again later.
    private func refresh(fetch: Bool) async {
        guard !refreshing else { return again = (again ?? false) || fetch }
        guard let executable = Bundle.main.executableURL else { return }
        refreshing = true
        defer {
            refreshing = false
            if let fetch = again {
                again = nil
                Task { await refresh(fetch: fetch) }
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.compileArgument] + (fetch ? [Self.fetchArgument] : []) + chosen.map(\.absoluteString)
        // Behind whatever is being done meanwhile.
        process.qualityOfService = .utility
        // Bound downloads and compilation together, including a stuck helper.
        let timeout = Task {
            try await Task.sleep(for: .seconds(300))
            if process.isRunning { process.terminate() }
        }
        defer { timeout.cancel() }
        let status = await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(returning: -1) }
        }
        guard status == 0 || status == Self.someMissing else { return failed = true }
        failed = status != 0
        if fetch {
            updated = .now
            UserDefaults.standard.set(Date.now, forKey: Self.fetchedKey)
        }
        named()
        use(await Self.compiled())
    }

    /// Lists added by address, named by their own title once fetched.
    private func named() {
        for (index, list) in added.enumerated() {
            guard let handle = try? FileHandle(forReadingFrom: list.cached) else { continue }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            if let line = head.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("! Title:") }) {
                added[index] = FilterList(title: line.dropFirst(8).trimmingCharacters(in: .whitespaces), url: list.url)
            }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(added), forKey: Self.addedKey)
    }

    /// The parts compiled last time, in order.
    private static func compiled() async -> [WKContentRuleList] {
        guard let store = WKContentRuleListStore.default() else { return [] }
        var parts: [WKContentRuleList] = []
        for index in 0... {
            guard let part = try? await store.contentRuleList(forIdentifier: prefix + "\(index)") else { break }
            parts.append(part)
        }
        return parts
    }

    /// What main.swift is given to be `compileAndExit` instead of the browser,
    /// then the lists' addresses.
    nonisolated static let compileArgument = "--compile-blocklist"
    /// Fetch every list anew, not only those not fetched before.
    nonisolated private static let fetchArgument = "--fetch"
    /// `compileAndExit`'s status when it compiled, but went without a list it never had.
    nonisolated private static let someMissing: Int32 = 3

    /// Fetches the lists, turns them into rules and compiles them into WebKit's
    /// store, where Nerda looks them up; then ends, 0 once they are there.
    static func compileAndExit() -> Never {
        let arguments = CommandLine.arguments.drop { $0 != compileArgument }.dropFirst()
        let fetch = arguments.contains(fetchArgument)
        let urls = arguments.filter { $0 != fetchArgument }.compactMap(URL.init(string:))
        Task {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var text = ""
            var missing = false
            for url in urls {
                let cached = FilterList(title: "", url: url).cached
                var list = fetch ? nil : try? String(contentsOf: cached, encoding: .utf8)
                if list == nil {
                    if let (data, response) = try? await session.data(from: url),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let fetched = ContentRules.downloadedList(data) {
                        try? FileManager.default.createDirectory(at: FilterList.folder, withIntermediateDirectories: true)
                        try? fetched.write(to: cached, atomically: true, encoding: .utf8)
                        list = fetched
                    } else {
                        NSLog("Nerda: couldn't fetch a valid block list from %@", url.absoluteString)
                        list = try? String(contentsOf: cached, encoding: .utf8)
                    }
                }
                if let list { text += list + "\n" } else { missing = true }
            }
            guard let parts = ContentRules.encode(text, partsOf: ContentRules.partLimit),
                  let store = WKContentRuleListStore.default() else { exit(1) }
            do {
                // ponytail: a part failing midway leaves the new parts before it
                // with the old after it, until the next refresh. Compile under a
                // new generation and switch if that ever matters.
                for (index, part) in parts.enumerated() {
                    _ = try await store.compileContentRuleList(forIdentifier: prefix + "\(index)", encodedContentRuleList: part)
                }
                for identifier in await store.availableIdentifiers() ?? [] where identifier == previous
                    || identifier.hasPrefix(prefix) && Int(identifier.dropFirst(prefix.count)).map({ $0 >= parts.count }) ?? false {
                    try? await store.removeContentRuleList(forIdentifier: identifier)
                }
                exit(missing ? someMissing : 0)
            } catch {
                NSLog("Nerda: couldn't compile the block list: \(error)")
                exit(1)
            }
        }
        // WebKit starts only on the main thread, which dispatchMain() would let go of.
        RunLoop.main.run()
        exit(1)
    }

    func use(_ lists: [WKContentRuleList]) {
        let old = rules
        rules = lists
        for controller in controllers.allObjects {
            old.forEach(controller.remove)
            if isEnabled { lists.forEach(controller.add) }
        }
    }
}

/// A list of filters to block with: one of the catalogue's, or one added by its address.
nonisolated struct FilterList: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let url: URL

    var id: URL { url }

    /// Where lists are kept as last fetched, to compile from without fetching again.
    static let folder = Edition.folder.appending(path: "Filter lists")

    var cached: URL {
        Self.folder.appending(path: url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.host() ?? "list")
    }

    /// A list added by address, until its own title is known: its file's name, or its site's.
    static func name(of url: URL) -> String {
        let file = url.lastPathComponent
        return file.isEmpty || file == "/" ? url.host() ?? url.absoluteString : file
    }

    /// The lists uBlock Origin offers (its assets.json), by heading, less those
    /// Nerda can take nothing from: `$removeparam`, `!#include` or uBO-only
    /// syntax. The first two are what Nerda blocks with until others are chosen.
    static let catalog: [(heading: String, lists: [FilterList])] = [
        ("Recommended", [
            FilterList(title: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
            FilterList(title: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
            FilterList(title: "uBlock filters – Ads", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!),
            FilterList(title: "uBlock filters – Badware risks", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.txt")!),
            FilterList(title: "uBlock filters – Privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!),
            FilterList(title: "uBlock filters – Unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!),
            FilterList(title: "uBlock filters – Quick fixes", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt")!),
            FilterList(title: "Online Malicious URL Blocklist", url: URL(string: "https://malware-filter.gitlab.io/urlhaus-filter/urlhaus-filter-ag-online.txt")!),
            FilterList(title: "Peter Lowe's Ad and tracking server list", url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext")!),
        ]),
        ("Ads", [
            FilterList(title: "AdGuard – Ads", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/2_without_easylist.txt")!),
            FilterList(title: "AdGuard – Mobile Ads", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/11.txt")!),
        ]),
        ("Privacy", [
            FilterList(title: "Block Outsider Intrusion into LAN", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/lan-block.txt")!),
        ]),
        ("Security", [
            FilterList(title: "Phishing URL Blocklist", url: URL(string: "https://malware-filter.gitlab.io/phishing-filter/phishing-filter.txt")!),
        ]),
        ("Annoyances", [
            FilterList(title: "AdGuard – Cookie Notices", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/18.txt")!),
            FilterList(title: "uBlock filters – Cookie Notices", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/annoyances-cookies.txt")!),
            FilterList(title: "EasyList – Cookie Notices", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-cookies.txt")!),
            FilterList(title: "AdGuard – Social Widgets", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/4.txt")!),
            FilterList(title: "EasyList – Social Widgets", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-social.txt")!),
            FilterList(title: "Fanboy – Anti-Facebook", url: URL(string: "https://secure.fanboy.co.nz/fanboy-antifacebook.txt")!),
            FilterList(title: "AdGuard – Popup Overlays", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/19.txt")!),
            FilterList(title: "AdGuard – Mobile App Banners", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/20.txt")!),
            FilterList(title: "AdGuard – Other Annoyances", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/21.txt")!),
            FilterList(title: "AdGuard – Widgets", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/22.txt")!),
            FilterList(title: "EasyList – Other Annoyances", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-annoyances.txt")!),
            FilterList(title: "EasyList – Chat Widgets", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-chat.txt")!),
            FilterList(title: "EasyList – AI Widgets", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-ai.txt")!),
            FilterList(title: "EasyList – Newsletter Notices", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-newsletters.txt")!),
            FilterList(title: "EasyList – Notifications", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist-notifications.txt")!),
        ]),
        ("Multipurpose", [
            FilterList(title: "Dan Pollock's hosts file", url: URL(string: "https://someonewhocares.org/hosts/hosts")!),
        ]),
        ("Regional", [
            FilterList(title: "Adblock List for Albania", url: URL(string: "https://raw.githubusercontent.com/AnXh3L0/blocklist/master/albanian-easylist-addition/Albania.txt")!),
            FilterList(title: "Liste AR", url: URL(string: "https://easylist-downloads.adblockplus.org/Liste_AR.txt")!),
            FilterList(title: "Bulgarian Adblock list", url: URL(string: "https://stanev.org/abp/adblock_bg.txt")!),
            FilterList(title: "AdGuard Chinese (中文)", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/224.txt")!),
            FilterList(title: "EasyList Czech and Slovak", url: URL(string: "https://raw.githubusercontent.com/tomasko126/easylistczechandslovak/master/filters.txt")!),
            FilterList(title: "EasyList Germany", url: URL(string: "https://easylist.to/easylistgermany/easylistgermany.txt")!),
            FilterList(title: "Eesti saitidele kohandatud filter", url: URL(string: "https://ubo-et.lepik.io/list.txt")!),
            FilterList(title: "Adblock List for Finland", url: URL(string: "https://raw.githubusercontent.com/finnish-easylist-addition/finnish-easylist-addition/gh-pages/Finland_adb.txt")!),
            FilterList(title: "AdGuard Français", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/16.txt")!),
            FilterList(title: "Greek AdBlock Filter", url: URL(string: "https://www.void.gr/kargig/void-gr-filters.txt")!),
            FilterList(title: "Dandelion Sprout's Serbo-Croatian filters", url: URL(string: "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/SerboCroatianList.txt")!),
            FilterList(title: "hufilter", url: URL(string: "https://cdn.jsdelivr.net/gh/hufilter/hufilter@gh-pages/hufilter-ublock.txt")!),
            FilterList(title: "ABPindo", url: URL(string: "https://raw.githubusercontent.com/ABPindo/indonesianadblockrules/master/subscriptions/abpindo.txt")!),
            FilterList(title: "IndianList", url: URL(string: "https://easylist-downloads.adblockplus.org/indianlist.txt")!),
            FilterList(title: "EasyList Hebrew", url: URL(string: "https://raw.githubusercontent.com/easylist/EasyListHebrew/master/EasyListHebrew.txt")!),
            FilterList(title: "EasyList Italy", url: URL(string: "https://easylist-downloads.adblockplus.org/easylistitaly.txt")!),
            FilterList(title: "AdGuard Japanese", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/7.txt")!),
            FilterList(title: "한국어 (Korean)", url: URL(string: "https://cdn.jsdelivr.net/npm/@filteringdev/filterslists-ko@latest/dist/filterslist-uBlockOrigin-classic.txt")!),
            FilterList(title: "EasyList Lithuania", url: URL(string: "https://raw.githubusercontent.com/EasyList-Lithuania/easylist_lithuania/master/easylistlithuania.txt")!),
            FilterList(title: "Latvian List", url: URL(string: "https://raw.githubusercontent.com/Latvian-List/adblock-latvian/master/lists/latvian-list.txt")!),
            FilterList(title: "Macedonian adBlock Filters", url: URL(string: "https://raw.githubusercontent.com/DeepSpaceHarbor/Macedonian-adBlock-Filters/master/Filters")!),
            FilterList(title: "AdGuard Dutch", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/8.txt")!),
            FilterList(title: "Dandelion Sprouts nordiske filtre", url: URL(string: "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/NorwegianList.txt")!),
            FilterList(title: "Oficjalne Polskie Filtry do uBlocka Origin", url: URL(string: "https://raw.githubusercontent.com/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock.txt")!),
            FilterList(title: "CERT.PL's Warning List", url: URL(string: "https://hole.cert.pl/domains/v2/domains_ublock.txt")!),
            FilterList(title: "Romanian Ad (ROad) Block List Light", url: URL(string: "https://raw.githubusercontent.com/tcptomato/ROad-Block/master/road-block-filters-light.txt")!),
            FilterList(title: "RU AdList", url: URL(string: "https://easylist-downloads.adblockplus.org/advblock.txt")!),
            FilterList(title: "RU AdList: Counters", url: URL(string: "https://raw.githubusercontent.com/easylist/ruadlist/master/cntblock.txt")!),
            FilterList(title: "EasyList Spanish", url: URL(string: "https://easylist-downloads.adblockplus.org/easylistspanish.txt")!),
            FilterList(title: "AdGuard Spanish/Portuguese", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/9.txt")!),
            FilterList(title: "Slovenian List", url: URL(string: "https://raw.githubusercontent.com/betterwebleon/slovenian-list/master/filters.txt")!),
            FilterList(title: "Frellwit's Swedish Filter", url: URL(string: "https://raw.githubusercontent.com/lassekongo83/Frellwits-filter-lists/master/Frellwits-Swedish-Filter.txt")!),
            FilterList(title: "EasyList Thailand", url: URL(string: "https://raw.githubusercontent.com/easylist-thailand/easylist-thailand/master/subscription/easylist-thailand.txt")!),
            FilterList(title: "AdGuard Turkish", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/13.txt")!),
            FilterList(title: "AdGuard Ukrainian", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/23.txt")!),
            FilterList(title: "ABPVN List", url: URL(string: "https://raw.githubusercontent.com/abpvn/abpvn/master/filter/abpvn_ublock.txt")!),
        ]),
    ]
}

/// Filter lines in EasyList's syntax, turned into WebKit's content rules. Only
/// what stops a load is kept: rules that hide parts of a page (`##`), and
/// those asking for more than a block (a redirect, a rewritten header), are
/// left out, as is any rule WebKit's rules can't say the same way.
/// Hosts files' lines are read as the names they block. Main-frame
/// navigation is always allowed. Generic filters apply only to third-party
/// requests, and known sign-in challenge services are exempt.
nonisolated enum ContentRules {
    /// Challenge services can be required for sign-in or checkout. EasyPrivacy
    /// deliberately targets some of them; compatibility takes priority here.
    static let botChecks = """
        @@||protechts.net^
        @@||perimeterx.net^
        @@||px-cdn.net^
        @@||px-cloud.net^
        @@||arkoselabs.com^
        @@||hcaptcha.com^
        """

    /// Rejects error pages, lists with nothing to block, and oversized
    /// downloads, before they can replace the last working list.
    static func downloadedList(_ data: Data) -> String? {
        guard data.count <= 10_000_000, let text = String(data: data, encoding: .utf8) else { return nil }
        let head = text.prefix(512).lowercased()
        guard !head.contains("<html"), !head.contains("<!doctype"),
              text.split(whereSeparator: \.isNewline).contains(where: { rule(String($0)) != nil }) else { return nil }
        return text
    }

    /// Rules in one compiled list, under WebKit's limit of 150,000.
    static let partLimit = 145_000

    /// The rules as WebKit reads them: blocks first, then the exceptions,
    /// which undo only what comes before them.
    static func encode(_ text: String) -> String? {
        encode(text, partsOf: .max)?.first
    }

    /// The same in parts of at most `limit` rules, for more than WebKit takes
    /// in one list. Each part has every exception, so a list's exceptions
    /// still undo another's blocks, whichever part those are in.
    static func encode(_ text: String, partsOf limit: Int) -> [String]? {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        let lines = (text + "\n" + botChecks).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // badfilter disables the matching filter, even when its options are reordered.
        func key(_ line: String) -> String {
            let (pattern, options) = parts(line)
            return pattern + "$" + options.filter { $0 != "badfilter" }.sorted().joined(separator: ",")
        }
        let disabled = Set(lines.filter { parts($0).1.contains("badfilter") }.map(key))
        var seen = Set<String>()
        for line in lines {
            guard seen.insert(line).inserted, !disabled.contains(key(line)),
                  let (rule, exception) = rule(line) else { continue }
            if exception { exceptions.append(rule) } else { blocks.append(rule) }
        }
        // These final rules protect typed addresses, links, redirects and popups,
        // including filters mixing subdocument with other resource types.
        exceptions.append(contentsOf: [
            ["trigger": ["url-filter": ".*", "resource-type": ["document"], "load-context": ["top-frame"]],
             "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": ".*", "resource-type": ["popup"]],
             "action": ["type": "ignore-previous-rules"]],
        ])
        let size = limit - exceptions.count
        guard size > 0 else { return nil }
        var encoded: [String] = []
        for start in stride(from: 0, to: max(blocks.count, 1), by: size) {
            guard let data = try? JSONSerialization.data(withJSONObject: Array(blocks[start..<min(start + size, blocks.count)]) + exceptions)
            else { return nil }
            encoded.append(String(decoding: data, as: UTF8.self))
        }
        return encoded
    }

    /// Every kind of load WebKit tells apart.
    private static let allTypes: Set<String> = [
        "document", "image", "style-sheet", "script", "font", "svg-document", "media", "ping",
        "fetch", "websocket", "other",
    ]

    /// What an option names, in WebKit's words.
    private static let types: [String: Set<String>] = [
        "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"], "font": ["font"],
        "media": ["media"], "other": ["other", "ping"], "xmlhttprequest": ["fetch"],
        "xhr": ["fetch"], "websocket": ["websocket"], "ping": ["ping"], "subdocument": ["document"],
    ]

    /// One filter line as a rule, and whether it is an exception; nil for a
    /// line that isn't a rule, or one that can't be kept.
    static func rule(_ line: String) -> ([String: Any], Bool)? {
        var line = line.trimmingCharacters(in: .whitespaces)
        // A hosts file's line, an address and a name to send there: the name blocked.
        let fields = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace)
        if fields.count >= 2, ["0.0.0.0", "127.0.0.1", "::", "::1"].contains(fields[0]) {
            let host = fields[1].lowercased()
            guard host.contains("."), validDomain(host) else { return nil }
            line = "||" + host + "^"
        }
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.hasPrefix("#"),
              !["##", "#@", "#?", "#$", "#%"].contains(where: line.contains) else { return nil }
        let exception = line.hasPrefix("@@")
        if exception { line.removeFirst(2) }

        let (pattern, options) = parts(line)
        guard !pattern.isEmpty, pattern != "||", pattern != "|" else { return nil }
        // Regular expressions: another dialect.
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil }

        var included = Set<String>()
        var excluded = Set<String>()
        var trigger: [String: Any] = [:]
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var wholePage = false
        for option in options {
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            if name.hasPrefix("domain=") {
                guard !negated else { return nil }
                for domain in name.dropFirst(7).split(separator: "|", omittingEmptySubsequences: false) {
                    let host = domain.hasPrefix("~") ? String(domain.dropFirst()) : String(domain)
                    guard validDomain(host) else { return nil }
                    if domain.hasPrefix("~") { unlessDomains.append("*" + host) } else { ifDomains.append("*" + host) }
                }
                continue
            }
            switch name {
            case "third-party", "3p": trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "first-party", "1p": trigger["load-type"] = [negated ? "third-party" : "first-party"]
            case "match-case": trigger["url-filter-is-case-sensitive"] = !negated
            // Every kind of load: as with no kind named, pages themselves being let through anyway.
            case "all": continue
            // WebKit cannot preserve important's priority over exceptions.
            case "important": return nil
            // An exception for a whole site: nothing blocked on its pages.
            // (Blocking whole pages is left to the pages' own warnings.)
            case "document", "doc":
                guard exception, !negated else { return nil }
                wholePage = true
            default:
                guard let type = types[name] else { return nil }
                // WebKit's "other" includes ping. Never widen an explicit block.
                if name == "other", !negated, !exception { return nil }
                if negated {
                    excluded.formUnion(type)
                    if name == "ping" { excluded.insert("other") }
                } else { included.formUnion(type) }
            }
        }
        // ponytail: WebKit cannot mix domain includes and excludes. Broaden
        // exceptions; split their scopes if the extra allowed ads matter.
        if !ifDomains.isEmpty, !unlessDomains.isEmpty {
            guard exception else { return nil }
            unlessDomains = []
        }
        // Keep generic filters away from first-party application endpoints,
        // including LinkedIn's /sensorCollect/. Site-scoped filters keep their scope.
        if !exception, ifDomains.isEmpty, trigger["load-type"] == nil { trigger["load-type"] = ["third-party"] }
        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
        if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }

        if wholePage {
            guard ifDomains.isEmpty, unlessDomains.isEmpty,
                  let filter = urlFilter(pattern) else { return nil }
            trigger["url-filter"] = ".*"
            trigger["if-top-url"] = [filter]
            return (["trigger": trigger, "action": ["type": "ignore-previous-rules"]], true)
        }

        guard let filter = urlFilter(pattern) else { return nil }
        trigger["url-filter"] = filter
        if !included.isEmpty || !excluded.isEmpty {
            let kinds = (included.isEmpty ? allTypes : included).subtracting(excluded)
            guard !kinds.isEmpty else { return nil }
            trigger["resource-type"] = kinds.sorted()
            // Frames only, not the page itself.
            if kinds == ["document"] { trigger["load-context"] = ["child-frame"] }
        }
        return (["trigger": trigger, "action": ["type": exception ? "ignore-previous-rules" : "block"]], exception)
    }

    private static func parts(_ line: String) -> (String, [String]) {
        guard let dollar = line.lastIndex(of: "$") else { return (line, []) }
        return (String(line[..<dollar]), line[line.index(after: dollar)...]
            .split(separator: ",").map { $0.lowercased() })
    }

    private static func validDomain(_ host: String) -> Bool {
        !host.isEmpty && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// The pattern as WebKit's regular expression: `||` any subdomain of the
    /// host, `|` an end of the address, `*` anything, `^` a separator.
    static func urlFilter(_ pattern: String) -> String? {
        var pattern = Substring(pattern)
        // WebKit serializes HTTP(S) host-only URLs with a slash. Avoid an
        // end-of-URL alternative on ~100,000 host rules: it makes the combined
        // automaton much larger, although it can never match such a request.
        let hostBoundary = pattern.hasPrefix("||") && pattern.hasSuffix("^")
            && validDomain(String(pattern.dropFirst(2).dropLast()))
        var filter = ""
        if pattern.hasPrefix("||") {
            pattern = pattern.dropFirst(2)
            filter = "^[^:]+://+([^:/]+\\.)?"
        } else if pattern.hasPrefix("|") {
            pattern = pattern.dropFirst()
            filter = "^"
        }
        var end = ""
        if pattern.hasSuffix("|") {
            pattern = pattern.dropLast()
            end = "$"
        }
        while end.isEmpty, pattern.hasSuffix("*") { pattern = pattern.dropLast() }
        guard pattern.allSatisfy(\.isASCII) else { return nil }
        let last = pattern.count - 1
        for (index, character) in pattern.enumerated() {
            switch character {
            case "*": filter += ".*"
            case "^":
                // WebKit has no alternation. A terminal separator also matches
                // the URL's end; an optional separator plus suffix expresses it.
                if index == last, !hostBoundary {
                    filter += end.isEmpty ? "([^a-zA-Z0-9_.%-].*)?$" : "[^a-zA-Z0-9_.%-]?"
                } else { filter += "[^a-zA-Z0-9_.%-]" }
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|": filter += "\\" + String(character)
            default: filter.append(character)
            }
        }
        while filter.hasPrefix(".*") { filter.removeFirst(2) }
        while end.isEmpty, filter.hasSuffix(".*") { filter.removeLast(2) }
        filter += end
        return filter.isEmpty ? ".*" : filter
    }
}
