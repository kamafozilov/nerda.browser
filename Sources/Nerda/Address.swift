import Foundation

/// What was typed, as somewhere to go: an address as it is, anything else
/// as a search, on the search engine chosen in the settings.
nonisolated enum Address {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") { return URL(string: text) }
        // A file on this Mac, by its path, as Chrome opens one.
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = NSString(string: text).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }

        guard !text.contains(" "), let typed = URL(string: "http://" + text),
              let host = typed.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              host.contains(".") || host.contains(":") || typed.port != nil || Browser.isThisMac(host)
        else { return search(text) }
        // Somewhere local (a server on this Mac, a router, a machine on the
        // network), or on a port of its own, answers http: https:// there
        // fails, as it did for 127.0.0.1:5173. The rest of the web is https,
        // as in Chrome.
        let plain = typed.port.map { $0 != 443 } ?? isLocal(host)
        return plain ? typed : URL(string: "https://" + text)
    }

    /// An IP address, or a name only a local network has: localhost, one
    /// word, or a name under a suffix kept for local use (.local, .test, …).
    static func isLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return host.contains(":") || !host.contains(".") || Browser.isThisMac(host)
            || parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
            || ["local", "localhost", "test", "internal", "lan", "home.arpa"].contains { host.hasSuffix("." + $0) }
    }

    static func search(_ text: String) -> URL? {
        SearchEngine.current.search(text)
    }

    /// What the search engine thinks is being searched for, as it would suggest
    /// under its own field; nothing when it can't be reached.
    static func suggestions(for text: String) async -> [String] {
        // ["query", ["suggestion", …], …]
        guard SearchSuggestions.isOn, let request = SearchEngine.current.guesses(text),
              let (data, _) = try? await URLSession.cookieless.data(from: request),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [Any],
              reply.count > 1, let suggestions = reply[1] as? [String]
        else { return [] }
        return suggestions
    }
}
