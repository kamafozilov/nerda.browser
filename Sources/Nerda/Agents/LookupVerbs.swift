import Foundation
import WebKit

/// What agents look up beside pages: a URL fetched with the profile's
/// cookies, without a tab; the owner's history and bookmarks, read and left
/// as they were; and the profile signed in to a site, to open tabs there.
/// All of it reads only. Past `fetch`, each sits in a group of tools an
/// agent asks for (`more_tools`), so the tool list it starts with is short.
nonisolated extension AgentVerb {
    static let lookupVerbs: [AgentVerb] = [fetch, moreTools, history, bookmarks, profiles]

    static let fetch = AgentVerb(
        name: "fetch",
        summary: """
            Read an address with the user's cookies, signed in as they are, without opening a tab: \
            cheap for an API, a feed or a file of text. GET only. Answers the status, type and the body \
            (its first \(AgentFetch.shownCharacters) characters).
            """,
        arguments: [.string("url", "The address to read, http or https"), .profile],
        readOnly: true
    ) { call in
        let url = try call.url()
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw AgentError(.invalid, "fetch reads http and https addresses; open \(url.absoluteString) in a tab instead.")
        }
        let store = call.server.agents(for: try call.profile()).browser.dataStore
        let cookies = await store.httpCookieStore.allCookies()
        return AgentFetch.answer(try await AgentFetch.get(url, cookies: cookies, agent: AgentFetch.userAgent,
                                                          timeout: call.remaining - .seconds(1)))
    }

    static let moreTools = AgentVerb(
        name: "more_tools",
        summary: """
            Add a group of tools to this list: \(ToolGroup.listed.map(\.name).joined(separator: ", ")). \
            Without a group, answers what each holds.
            """,
        arguments: [.string("group", "The group to add, such as history", required: false)],
        readOnly: true
    ) { call in
        // The MCP shim does it itself (AgentMCP), as the list is its own;
        // anyone else is told what the groups hold.
        ToolGroup.describe(try ToolGroup.named(call.optionalString("group")))
    }

    static let history = AgentVerb(
        name: "history",
        summary: """
            Search the pages the user visited, latest first: each with when, its title and address. \
            Every word must be in the title or address. Changes nothing.
            """,
        arguments: [
            .string("query", "Words to look for, such as invoice march; none lists the latest pages", required: false),
            .integer("days", "Only pages visited in the last this many days"),
            .integer("limit", "How many pages at most (\(historyLimit) unless given, up to \(historyMost))"),
            .profile,
        ],
        readOnly: true, group: .history
    ) { call in
        let profile = try call.profile()
        let query = call.optionalString("query")?.trimmingCharacters(in: .whitespaces) ?? ""
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let days = call.arguments["days"]?.int
        let limit = min(max(call.arguments["limit"]?.int ?? historyLimit, 1), historyMost)
        let start = days.map { Date.now.addingTimeInterval(-Double($0) * 24 * 60 * 60) } ?? .distantPast
        let history = profile.history
        // What is still being read from disk is taken in first: that only reads.
        history.settle()
        let visits = history.pages(containing: words, from: start, limit: limit)
        let which = (query.isEmpty ? "" : " matching \"\(query)\"") + (days.map { " in the last \($0) days" } ?? "")
        guard !visits.isEmpty else { return "No pages in \(profile.name)'s history\(which)." }
        let lines = visits.map { visit in
            let times = visit.count == 1 ? "1 visit" : "\(visit.count) visits"
            return "\(AgentFetch.when(visit.last))  \(visit.title.isEmpty ? "(no title)" : visit.title)  \(visit.url.absoluteString)  (\(times))"
        }
        return """
            \(profile.name)'s history\(which), latest first (\(visits.count)\(visits.count == limit ? ", more with a higher limit" : "")):
            \(AgentPage.untrusted(lines.joined(separator: "\n")))
            """
    }

    static let bookmarks = AgentVerb(
        name: "bookmarks",
        summary: """
            Read the user's bookmarks: every one in its folders, or those whose title or address has \
            every word of a query. Changes nothing.
            """,
        arguments: [.string("query", "Words to look for; none lists them all", required: false), .profile],
        readOnly: true, group: .bookmarks
    ) { call in
        let profile = try call.profile()
        let query = call.optionalString("query")?.trimmingCharacters(in: .whitespaces) ?? ""
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        var lines: [String] = []
        func walk(_ items: [Bookmarks.Item], in folders: [String]) {
            for item in items {
                if let children = item.children {
                    if words.isEmpty { lines.append(String(repeating: "  ", count: folders.count) + item.title + "/") }
                    walk(children, in: folders + [item.title])
                } else if let url = item.url {
                    if words.isEmpty {
                        lines.append(String(repeating: "  ", count: folders.count) + "\(item.title)  \(url.absoluteString)")
                    } else if words.allSatisfy({ fold(item.title + " " + url.absoluteString).contains($0) }) {
                        let place = folders.isEmpty ? "" : folders.joined(separator: " / ") + " / "
                        lines.append("\(place)\(item.title)  \(url.absoluteString)")
                    }
                }
            }
        }
        walk(profile.bookmarks.items, in: [])
        let which = query.isEmpty ? "" : " matching \"\(query)\""
        guard !lines.isEmpty else { return "No bookmarks in \(profile.name)\(which)." }
        let shown = lines.prefix(bookmarksMost)
        var answer = "\(profile.name)'s bookmarks\(which):\n" + AgentPage.untrusted(shown.joined(separator: "\n"))
        if lines.count > shown.count { answer += "\n(\(lines.count - shown.count) more lines: narrow with a query)" }
        return answer
    }

    static let profiles = AgentVerb(
        name: "profiles",
        summary: """
            The user's profiles, each signed in to sites of its own. With a site, which of them is \
            signed in there, from its cookies; then open tabs there with open's profile.
            """,
        arguments: [.string("site", "A site or address, such as github.com", required: false)],
        readOnly: true, group: .profiles
    ) { call in
        let profiles = call.server.profiles
        guard let site = call.optionalString("site")?.trimmingCharacters(in: .whitespaces), !site.isEmpty else {
            let names = profiles.enumerated().map { $0 == 0 ? "\($1.name) (the default)" : $1.name }
            return "Profiles: \(names.joined(separator: ", ")). Give a site to see which is signed in there."
        }
        guard let host = (site.contains("://") ? URL(string: site) : URL(string: "https://" + site))?.host()?.lowercased() else {
            throw AgentError(.invalid, "\(site) is not a site, such as github.com.")
        }
        var found: [(profile: Profile, all: [HTTPCookie], signIn: [HTTPCookie])] = []
        for profile in profiles {
            let cookies = await call.server.agents(for: profile).browser.dataStore.httpCookieStore.allCookies()
                .filter { AgentFetch.cookie($0, isFor: host) }
            found.append((profile, cookies, cookies.filter(AgentFetch.signsIn)))
        }
        // Signed in first, then those with some cookies, in the profiles' order.
        func rank(_ cookies: (all: [HTTPCookie], signIn: [HTTPCookie])) -> Int {
            !cookies.signIn.isEmpty ? 0 : !cookies.all.isEmpty ? 1 : 2
        }
        let lines = found.sorted { rank(($0.all, $0.signIn)) < rank(($1.all, $1.signIn)) }
            .map { profile, all, signIn in
                if !signIn.isEmpty {
                    return "\(profile.name): likely signed in (\(signIn.map(\.name).joined(separator: ", ")) among \(all.count) cookies)"
                }
                if !all.isEmpty { return "\(profile.name): no sign-in cookie seen (\(all.count) cookies)" }
                return "\(profile.name): no cookies"
            }
        return "Profiles for \(host), from their cookies:\n" + lines.joined(separator: "\n")
            + "\nOpen a tab in one with open and its profile, such as profile: \(found.first { !$0.signIn.isEmpty }?.profile.name ?? profiles.first?.name ?? "Personal")."
    }

    /// History pages answered unless asked for more, and the most.
    static let historyLimit = 20
    static let historyMost = 200
    /// Lines of bookmarks answered at most.
    static let bookmarksMost = 500

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

nonisolated extension AgentArgument {
    /// The profile a verb works in, by name.
    static let profile = string("profile", "The user's profile to use, by name; Personal unless given (see profiles)", required: false)
}

extension AgentCall {
    /// The profile named by the argument, by name, case aside; the first
    /// (Personal) when none is given. Incognito is no profile.
    func profile(_ name: String = "profile") throws -> Profile {
        let profiles = server.profiles
        guard let asked = optionalString(name)?.trimmingCharacters(in: .whitespaces), !asked.isEmpty else {
            return profiles.first ?? .main
        }
        let found = profiles.first { $0.name.compare(asked, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? profiles.first { $0.id.uuidString.caseInsensitiveCompare(asked) == .orderedSame }
        guard let found else {
            throw AgentError(.invalid, "There is no profile \(asked). The profiles: \(profiles.map(\.name).joined(separator: ", ")).")
        }
        return found
    }
}

/// A group of tools listed only once an agent asks for it with
/// `more_tools` (`AgentVerb.group`): the page verbs are listed from the
/// start, the rest when wanted, so the list an agent starts with is short.
nonisolated struct ToolGroup: Hashable, Sendable {
    let name: String
    let summary: String

    static let history = ToolGroup(name: "history", summary: "search the pages the user visited")
    static let bookmarks = ToolGroup(name: "bookmarks", summary: "read the user's bookmarks")
    static let profiles = ToolGroup(name: "profiles", summary: "find the profile signed in to a site, to open tabs there")
    static let skills = ToolGroup(name: "skills", summary: "read a Site skill, what is known to work on a site, and save one")

    /// Every group, in the order `more_tools` names them. A ticket adding a
    /// group adds it here.
    static let listed: [ToolGroup] = [history, bookmarks, profiles, skills]

    /// The group of that name; nil for none asked. One there isn't fails,
    /// naming those there are.
    static func named(_ name: String?) throws -> ToolGroup? {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        guard let group = listed.first(where: { $0.name == name }) else {
            throw AgentError(.invalid, "There is no group \(name). The groups: \(listed.map(\.name).joined(separator: ", ")).")
        }
        return group
    }

    /// What `more_tools` answers: the group's tools, now listed; or, for
    /// none, every group and what it holds.
    static func describe(_ group: ToolGroup?) -> String {
        guard let group else {
            return "Groups of more tools; add one with more_tools and its group:\n" + listed.map { group in
                "\(group.name): \(group.summary) (\(group.verbs.map(\.name).joined(separator: ", ")))"
            }.joined(separator: "\n")
        }
        return "Added the \(group.name) tools:\n" + group.verbs.map { "\($0.name): \($0.summary)" }.joined(separator: "\n")
    }

    var verbs: [AgentVerb] { AgentVerb.all.filter { $0.group == self } }
}

/// `fetch`'s request: a GET in a session of its own, thrown away after,
/// holding a copy of the profile's cookies. What the site sets comes back
/// into that copy only, so nothing of the profile changes.
nonisolated enum AgentFetch {
    /// The most of a body read: past it, the rest isn't fetched.
    static let mostBytes = 2 << 20
    /// The most of a body's text shown the agent, as for a page's outline.
    static let shownCharacters = 40_000

    /// Safari's, as Nerda's pages send.
    @MainActor static var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(Tab.applicationName)"
    }

    /// The answer, as its header lines and the body's text (nil when it
    /// isn't text), read off the main thread.
    static func get(_ url: URL, cookies: [HTTPCookie], agent: String, timeout: Duration) async throws
        -> (header: [String], text: String?) {
        let configuration = URLSessionConfiguration.ephemeral
        let seconds = max(1, Double(timeout.components.seconds))
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .always
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")

        let bytes: URLSession.AsyncBytes, response: URLResponse
        var body = Data()
        var cut = false
        do {
            (bytes, response) = try await session.bytes(for: request)
            for try await byte in bytes {
                guard body.count < mostBytes else {
                    cut = true
                    break
                }
                body.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentError(.failed, "\(url.absoluteString) couldn't be fetched: \(error.localizedDescription)")
        }

        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? ""
        var lines: [String] = []
        if let http {
            lines.append("status: \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
        }
        lines.append("address: \((response.url ?? url).absoluteString)")
        if !type.isEmpty { lines.append("type: \(type)") }
        lines.append("size: \(body.count) bytes" + (cut ? ", the first only: the rest wasn't fetched" : ""))
        return (lines, text(of: body, type: type, encoding: response.textEncodingName))
    }

    /// What the agent is told of a fetch.
    @MainActor static func answer(_ fetched: (header: [String], text: String?)) -> String {
        var lines = fetched.header
        guard let text = fetched.text else {
            lines.append("Not text, so not shown: open it in a tab to see it.")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        lines.append(AgentPage.untrusted(String(text.prefix(shownCharacters))))
        if text.count > shownCharacters { lines.append("(\(text.count - shownCharacters) more characters)") }
        return lines.joined(separator: "\n")
    }

    /// The body as text, if it is text: by its type, or, with none, if it reads as UTF-8.
    private static func text(of body: Data, type: String, encoding: String?) -> String? {
        let type = type.lowercased()
        let textual = type.hasPrefix("text/") || ["json", "xml", "javascript", "ecmascript", "csv", "yaml", "x-www-form-urlencoded"]
            .contains { type.contains($0) }
        guard textual || type.isEmpty else { return nil }
        if let name = encoding {
            let converted = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if converted != kCFStringEncodingInvalidId,
               let text = String(data: body, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))) {
                return text
            }
        }
        if let text = String(data: body, encoding: .utf8) { return text }
        return textual ? String(decoding: body, as: UTF8.self) : nil
    }

    /// Whether the cookie goes with requests to `host`, or to a site under
    /// it (accounts.google.com's for google.com).
    static func cookie(_ cookie: HTTPCookie, isFor host: String) -> Bool {
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix("." + host)
    }

    /// Whether a cookie looks like one that keeps someone signed in, by its
    /// name: a guess, as no site says.
    static func signsIn(_ cookie: HTTPCookie) -> Bool {
        let name = cookie.name.lowercased()
        return ["sess", "auth", "token", "login", "logged", "sid", "user", "account", "jwt", "remember"]
            .contains { name.contains($0) }
    }

    /// A visit's date, as agents read it.
    static func when(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }
}
