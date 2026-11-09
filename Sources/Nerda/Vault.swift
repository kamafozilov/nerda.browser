import Foundation
import Security
import os

/// A saved sign-in, without its password, which is read from the keychain
/// only as it goes into a page.
nonisolated struct Account: Hashable, Sendable {
    /// Where it was used, as `Site.key` has it.
    let host: String
    let user: String
    /// The service it signs in with (`SocialSignIn.Provider.id`), as Sign in
    /// with Google does: no password of its own. Nil for a password.
    var provider: String? = nil
}

/// Every saved sign-in. The passwords are one item in the login keychain; the
/// names they go with (site and user, nothing secret) are a file beside the
/// history, so listing a site's accounts under its sign-in box never touches
/// the keychain. The keychain asks before handing its item to an app that
/// isn't the one that saved it, and to it every build not signed with a team
/// (an Apple Development certificate) is another app: kept like this, that is
/// one question after such a build, and only once a password is really wanted,
/// picked or saved.
actor Vault {
    static let shared = Vault(service: "\(Edition.name) Passwords",
                              names: Edition.folder.appending(path: "accounts.json"))

    /// As kept in the keychain.
    nonisolated struct Login: Codable, Sendable {
        var host: String
        var user: String
        var password: String
        var saved: Date
        /// Last used on a page that came over plain http; nil for https, as
        /// every login kept before this was taken to be.
        var clear: Bool?
        /// When it last went into a page or signed someone in; nil if never
        /// since it was saved. As the names have it at the last save: they
        /// keep it between saves, without the keychain.
        var used: Date?
        /// As `Account.provider`; such a login's password is empty.
        var provider: String?
        /// Written in the Vault window: a recovery code, a security answer.
        /// Only here, never in the file of names.
        var note: String?

        var account: Account { Account(host: host, user: user, provider: provider) }
        var name: Name {
            Name(host: host, user: user, saved: saved, clear: clear, used: used, provider: provider, noted: note == nil ? nil : true)
        }
    }

    /// As kept in the file: a login without its password.
    nonisolated struct Name: Codable, Sendable {
        var host: String
        var user: String
        var saved: Date
        var clear: Bool?
        var used: Date?
        var provider: String?
        /// It has a note, which only the keychain holds.
        var noted: Bool?

        var account: Account { Account(host: host, user: user, provider: provider) }
        /// Saving one is using it: it was just typed in, and it worked.
        var lastUsed: Date { max(used ?? saved, saved) }
    }

    /// Those that may be offered on a page: on one that came over plain
    /// http, which anyone on the network in between (a café's, a hotel's)
    /// could have written, only those last used on such a page, never a
    /// password kept from the site over https.
    nonisolated static func offered(_ names: [Name], clear: Bool) -> [Name] {
        clear ? names.filter { $0.clear == true } : names
    }

    private let service: String
    private let namesFile: URL
    /// Newest first; nil until read.
    private var names: [Name]?
    /// The file wasn't there: made again from the keychain once that is read.
    private var namesLost = false
    /// With their passwords; nil until read, and while the keychain won't hand them over.
    private var logins: [Login]?
    /// Asked this run, and told no: not asked again until the next.
    private var refused = false
    /// Its profile is being deleted: neither the file nor the keychain is written again.
    private var closed = false

    init(service: String, names: URL) {
        self.service = service
        self.namesFile = names
    }

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func loadNames() -> [Name] {
        if let names { return names }
        let data = try? Data(contentsOf: namesFile)
        namesLost = data == nil
        let read = data.flatMap { try? JSONDecoder().decode([Name].self, from: $0) } ?? []
        names = read
        return read
    }

    /// The names, made again from the keychain if the file is gone (lost, or
    /// from before there was one): the one case listing asks the keychain.
    private func knownNames() -> [Name] {
        let names = loadNames()
        guard namesLost else { return names }
        _ = loadLogins()
        return self.names ?? names
    }

    /// The sign-ins with their passwords; nil when they can't be had. Never
    /// guessed at: a store that couldn't be read is never written over.
    private func loadLogins() -> [Login]? {
        if let logins { return logins }
        if refused { return nil }
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &found) {
        case errSecSuccess:
            logins = (found as? Data).flatMap { try? JSONDecoder().decode([Login].self, from: $0) }
        case errSecItemNotFound:
            logins = []
        default:
            refused = true
        }
        _ = loadNames()
        if namesLost, let logins { writeNames(logins.map(\.name)) }
        return logins
    }

    private func writeNames(_ new: [Name]) {
        names = new
        namesLost = false
        guard !closed else { return }
        do {
            try FileManager.default.createDirectory(at: namesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: namesFile, options: .atomic)
        } catch {
            Logger.passwords.error("couldn't save the names of saved passwords: \(String(describing: error), privacy: .private)")
        }
    }

    private func store(_ new: [Login]) -> Bool {
        guard !closed else { return false }
        // When each was last used is the names', written on every use without
        // the keychain; it goes into the keychain with a save.
        let used = Dictionary(loadNames().map { ($0.account, $0.used) }, uniquingKeysWith: { first, _ in first })
        let sorted = new.map { login in
            var login = login
            login.used = used[login.account] ?? login.used
            return login
        }.sorted { $0.saved > $1.saved }
        guard let data = try? JSONEncoder().encode(sorted) else { return false }
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        logins = sorted
        writeNames(sorted.map(\.name))
        return true
    }

    /// Those still kept: one forgotten while the keychain wasn't read stays in
    /// it until the next save, and counts as gone meanwhile.
    private func kept(_ logins: [Login]) -> [Login] {
        let accounts = Set(loadNames().map(\.account))
        return logins.filter { accounts.contains($0.account) }
    }

    /// The accounts for `host`'s site, the one used last first, for a page
    /// that came over plain http (`clear`) or not. From the file, without the
    /// keychain, unless the file has to be made again.
    func accounts(for host: String, clear: Bool) -> [Account] {
        let names = Self.offered(knownNames(), clear: clear)
        let lastUsed = Dictionary(names.map { ($0.account, $0.lastUsed) }, uniquingKeysWith: max)
        return Site.matching(names.map(\.account), host).sorted { lastUsed[$0]! > lastUsed[$1]! }
    }

    /// They were just used, put into a page or signed in with: listed first
    /// from now on. In the file only, so filling never asks the keychain to
    /// write; it keeps the date from the next save on.
    func touch(_ accounts: [Account]) {
        guard !accounts.isEmpty else { return }
        writeNames(knownNames().map { name in
            var name = name
            if accounts.contains(name.account) { name.used = .now }
            return name
        })
    }

    func password(for account: Account) -> String? {
        login(for: account)?.password
    }

    /// With its password and note, for the Vault window.
    func login(for account: Account) -> Login? {
        guard knownNames().contains(where: { $0.account == account }) else { return nil }
        return loadLogins()?.first { $0.account == account }
    }

    /// Every one kept, with its password and note: for the Vault window's
    /// security check and export. Nil when the keychain won't hand them over.
    func everything() -> [Login]? {
        loadLogins().map(kept)
    }

    /// Whether a sign-in with this service on the site is kept already,
    /// under this name or, for a name not known, any: those are counted as
    /// used now. From the file, without the keychain.
    func recall(_ account: Account) -> Bool {
        let same = knownNames().map(\.account).filter {
            $0.provider == account.provider && Site.of($0.host) == Site.of(account.host)
                && (account.user.isEmpty || $0.user == account.user)
        }
        touch(same)
        return !same.isEmpty
    }

    /// Whether this name's password for the site is kept already, and whether
    /// one (another) is kept for it on this very host; nil when the keychain
    /// won't say, as then nothing could be kept either. A name not kept for
    /// the site at all needs no keychain to tell.
    func check(_ sent: SentSignIn) -> (known: Bool, replaces: Bool)? {
        let same = knownNames().map(\.account)
            .filter { $0.provider == nil && $0.user == sent.user && Site.of($0.host) == Site.of(sent.host) }
        guard !same.isEmpty else { return (false, false) }
        guard let all = loadLogins() else { return nil }
        let known = all.filter { same.contains($0.account) && $0.password == sent.password }.map(\.account)
        touch(known)
        // Where it was used last is where it is offered from now on: one kept
        // over https and typed into the site's plain http page by hand (a
        // router's) is offered there too, and once used over https again, no longer.
        let clear = sent.clear ? true : nil
        if all.contains(where: { known.contains($0.account) && $0.clear != clear }) {
            _ = store(kept(all).map { login in
                var login = login
                if known.contains(login.account) { login.clear = clear }
                return login
            })
        }
        return (!known.isEmpty, same.contains { $0.host == sent.host })
    }

    /// Adds them, or replaces those kept already, keeping their notes; all or
    /// none. `clear`: from a page that came over plain http.
    func save(_ new: [(Account, String)], clear: Bool = false) -> Bool {
        guard let loaded = loadLogins() else { return false }
        var all = kept(loaded)
        for (account, password) in new {
            let note = all.first { $0.account == account }?.note
            all.removeAll { $0.account == account }
            all.append(Login(host: account.host, user: account.user, password: password, saved: .now,
                             clear: clear ? true : nil, provider: account.provider, note: note))
        }
        return store(all)
    }

    func close() {
        closed = true
    }

    /// Every saved sign-in, without its password: the Vault window's list,
    /// from the file, as the list under a sign-in box is.
    func all() -> [Name] {
        knownNames()
    }

    /// One changed in the Vault window, its site, name, password or note; all
    /// or none. It keeps whether it was last used over plain http, and when
    /// it was saved unless its password changed.
    func change(_ old: Account, to new: Account, password: String, note: String?) -> Bool {
        guard let loaded = loadLogins() else { return false }
        var all = kept(loaded)
        let was = all.first { $0.account == old }
        all.removeAll { $0.account == old || $0.account == new }
        let saved = was.flatMap { $0.password == password ? $0.saved : nil } ?? .now
        all.append(Login(host: new.host, user: new.user, password: password, saved: saved, clear: was?.clear,
                         provider: new.provider, note: note?.isEmpty == false ? note : nil))
        return store(all)
    }

    /// Gone from the list at once, without asking the keychain for anything;
    /// from the keychain too if it has been read this run, else with the next save.
    func forget(_ account: Account) {
        let rest = knownNames().filter { $0.account != account }
        if let logins {
            names = rest
            _ = store(kept(logins))
        } else {
            writeNames(rest)
        }
    }
}

/// Which saved passwords belong to which page. A password kept for
/// accounts.example.com is offered on example.com too, as it is one site.
nonisolated enum Site {
    /// The host a password is kept under: lower case, without www.
    static func key(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The site a host belongs to: example.com for login.example.com,
    /// example.co.uz for mail.example.co.uz, and alice.github.io for
    /// www.alice.github.io, as github.io is anyone's to register under.
    static func of(_ host: String) -> String {
        let host = key(host)
        let labels = host.split(separator: ".").map(String.init)
        // An address (127.0.0.1, ::1) is a site of its own.
        if host.contains(":") || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        guard labels.count > 2 else { return host }
        // One name more than the longest ending anyone can register under.
        if let isSuffix = publicSuffix {
            for count in stride(from: labels.count - 1, through: 1, by: -1)
            where isSuffix(labels.suffix(count).joined(separator: ".") as CFString) {
                return labels.suffix(count + 1).joined(separator: ".")
            }
            return host
        }
        // Without it: a few rules and a list of shared hosts.
        let last2 = labels.suffix(2).joined(separator: ".")
        let isSuffix = sharedHosts.contains(last2)
            || (labels[labels.count - 1].count == 2 && secondLevels.contains(labels[labels.count - 2]))
        return labels.suffix(isSuffix ? 3 : 2).joined(separator: ".")
    }

    /// Of `accounts`, those for `host`'s site: its own first, then the rest of the site's.
    static func matching(_ accounts: [Account], _ host: String) -> [Account] {
        let host = key(host)
        let site = of(host)
        return accounts.filter { $0.host == host } + accounts.filter { $0.host != host && of($0.host) == site }
    }

    /// Whether a name is one anyone can register under (com, co.uk, github.io,
    /// myshopify.com), from the public suffix list macOS keeps, as WebKit asks
    /// it for cookies. Private to CFNetwork: should it go, the rules below.
    private static let publicSuffix: (@convention(c) (CFString) -> Bool)? = {
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW),
                                 "_CFHostIsDomainTopLevel") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFString) -> Bool).self)
    }()

    /// co.uk, com.uz and the like: under a country's two letters, the part
    /// everyone registers under.
    private static let secondLevels: Set = ["ac", "co", "com", "edu", "gov", "govt", "mil", "ne", "net", "or", "org"]
    /// Hosts whose every subdomain is someone else's site.
    private static let sharedHosts: Set = [
        "appspot.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "firebaseapp.com", "fly.dev",
        "github.io", "gitlab.io", "glitch.me", "herokuapp.com", "netlify.app", "ngrok.io", "onrender.com",
        "pages.dev", "vercel.app", "web.app", "workers.dev",
    ]
}

