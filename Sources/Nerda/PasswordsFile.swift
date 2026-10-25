import Foundation

/// Passwords exported by another app, as CSV: Passwords (and Safari) write
/// Title, URL, Username, Password, …; Chrome name, url, username, password.
/// Nerda writes Chrome's, which Passwords, Safari, Chrome, Firefox and the
/// password managers all read.
nonisolated enum PasswordsFile {
    /// The passwords, with their notes, by site. A sign-in with another
    /// service has no password to take elsewhere, and is left out.
    static func csv(_ logins: [Vault.Login]) -> String {
        let rows = logins.filter { $0.provider == nil }
            .sorted { ($0.host, $0.user.lowercased()) < ($1.host, $1.user.lowercased()) }
            .map { [$0.host, "\($0.clear == true ? "http" : "https")://\($0.host)/", $0.user, $0.password, $0.note ?? ""] }
        return ([["name", "url", "username", "password", "note"]] + rows)
            .map { $0.map(field).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    /// In quotes when it holds a comma, a quote or a line break, its quotes doubled.
    private static func field(_ text: String) -> String {
        guard text.contains(where: { [",", "\"", "\n", "\r"].contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func logins(in text: String) -> [(Account, String)] {
        var rows = rows(text)
        guard !rows.isEmpty else { return [] }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: Set<String>) -> Int? { header.firstIndex(where: names.contains) }
        guard let url = column(["url", "login_uri", "website"]),
              let user = column(["username", "login_username"]),
              let password = column(["password", "login_password"]) else { return [] }
        var logins: [Account: String] = [:]
        for row in rows where row.count > max(url, user, password) && !row[password].isEmpty {
            let address = row[url].trimmingCharacters(in: .whitespaces)
            guard let host = URL(string: address.contains("://") ? address : "https://" + address)?.host(),
                  !host.isEmpty else { continue }
            logins[Account(host: Site.key(host), user: row[user])] = row[password]
        }
        return logins.map { ($0.key, $0.value) }
    }

    /// Fields in quotes may hold commas, doubled quotes and line breaks.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var wasQuote = false
        for character in text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text {
            if quoted {
                if character == "\"" { quoted = false; wasQuote = true } else { field.append(character) }
                continue
            }
            switch character {
            case "\"":
                // A doubled quote inside quotes is a quote.
                if wasQuote { field.append("\"") }
                quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r", "\r\n":
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            default:
                field.append(character)
            }
            wasQuote = false
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}

