import Foundation
import Observation
import WebKit

/// Ads and trackers, stopped where WebKit loads things (decisions #8), so a
/// page never spends time, memory or battery on them. The lists most blockers
/// start from, EasyList and EasyPrivacy, are fetched from easylist.to, and
/// again every few days, turned into WebKit's content rules (`ContentRules`)
/// and compiled once per new list. WebKit keeps what it compiled: a launch
/// only looks it up. Until there is a list, pages load as they are.
@MainActor
@Observable
final class Blocker {
    static let shared = Blocker()

    private static let lists = [
        URL(string: "https://easylist.to/easylist/easylist.txt")!,
        URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
    ]
    /// How long a list is used before it is fetched again.
    private static let refreshAfter: TimeInterval = 4 * 24 * 60 * 60
    // Version the compiled artifact too: unsafe rules from an older converter
    // must never be installed while an update is pending or the Mac is offline.
    private static let identifier = "blocklist-v3"
    private static let fetchedKey = identifier + "-fetched"

    var isEnabled = UserDefaults.standard.object(forKey: "blockAdsAndTrackers") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "blockAdsAndTrackers")
            guard let rules else { return }
            for controller in controllers.allObjects {
                controller.remove(rules)
                if isEnabled { controller.add(rules) }
            }
        }
    }

    private(set) var rules: WKContentRuleList?
    /// Every page's controller, given the rules as they come, and each new list.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var refreshing = false
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
            if let list = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: Self.identifier) {
                use(list)
            }
            if rules == nil || isDue { await refresh() }
            settled = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
        // A Mac left on for days still gets new lists.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDue else { return }
                Task { await self.refresh() }
            }
        }
        timer?.tolerance = 60 * 60
    }

    /// A page's controller: it blocks with the rules from now on, and each list after.
    func install(in controller: WKUserContentController) {
        controllers.add(controller)
        if isEnabled, let rules { controller.add(rules) }
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

    /// New lists, fetched and compiled by Nerda run again as a process of its
    /// own (`compileAndExit`): the ~300 MB it takes goes when it does, rather
    /// than staying with Nerda. A list that can't be had leaves the last one
    /// in use, and is tried again later.
    private func refresh() async {
        guard !refreshing, let executable = Bundle.main.executableURL else { return }
        refreshing = true
        defer { refreshing = false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.compileArgument]
        // Behind whatever is being done meanwhile.
        process.qualityOfService = .utility
        // Bound downloads and compilation together, including a stuck helper.
        let timeout = Task {
            try await Task.sleep(for: .seconds(120))
            if process.isRunning { process.terminate() }
        }
        defer { timeout.cancel() }
        let compiled = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
        guard compiled, let list = try? await WKContentRuleListStore.default()
            .contentRuleList(forIdentifier: Self.identifier) else { return }
        UserDefaults.standard.set(Date.now, forKey: Self.fetchedKey)
        use(list)
    }

    /// What main.swift is given to be `compileAndExit` instead of the browser.
    nonisolated static let compileArgument = "--compile-blocklist"

    /// Fetches the lists, turns them into rules and compiles them into WebKit's
    /// store, where Nerda looks them up; then ends, 0 once they are there.
    static func compileAndExit() -> Never {
        Task {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var text = ""
            for url in lists {
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let list = ContentRules.downloadedList(data) else {
                    NSLog("Nerda: couldn't fetch a valid block list from %@", url.absoluteString)
                    exit(1)
                }
                text += list + "\n"
            }
            guard let encoded = ContentRules.encode(text) else { exit(1) }
            do {
                let list = try await WKContentRuleListStore.default()
                    .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded)
                exit(list == nil ? 1 : 0)
            } catch {
                NSLog("Nerda: couldn't compile the block list: \(error)")
                exit(1)
            }
        }
        // WebKit starts only on the main thread, which dispatchMain() would let go of.
        RunLoop.main.run()
        exit(1)
    }

    func use(_ list: WKContentRuleList) {
        let old = rules
        rules = list
        for controller in controllers.allObjects {
            if let old { controller.remove(old) }
            if isEnabled { controller.add(list) }
        }
    }
}

/// Filter lines in EasyList's syntax, turned into WebKit's content rules. Only
/// what stops a load is kept: rules that hide parts of a page (`##`), and
/// those asking for more than a block (a redirect, a rewritten header), are
/// left out, as is any rule WebKit's rules can't say the same way.
/// Main-frame navigation is always allowed. Generic filters apply only to
/// third-party requests, and known sign-in challenge services are exempt.
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

    /// Reject error pages, incomplete lists and oversized downloads before
    /// they can replace the last working list. Only the two fixed sources use this.
    static func downloadedList(_ data: Data) -> String? {
        guard data.count <= 10_000_000, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("[Adblock Plus "), text.contains("\n! Title:"),
              text.contains("\n! Version:"), text.split(separator: "\n").count > 100 else { return nil }
        return text
    }

    /// The rules as WebKit reads them: blocks first, then the exceptions,
    /// which undo only what comes before them.
    static func encode(_ text: String) -> String? {
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
        guard let data = try? JSONSerialization.data(withJSONObject: blocks + exceptions) else { return nil }
        return String(decoding: data, as: UTF8.self)
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
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["),
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
