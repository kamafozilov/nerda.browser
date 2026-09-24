import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Passwords, kept in the login keychain as Safari's once were: saved when a
// sign-in has worked, offered under the sign-in box when it is clicked, and
// never put into a page until one is picked. Safari's own, in the Passwords
// app, are out of reach (Apple keeps them for itself and a few browsers it
// knows); they come in once, from the file Passwords exports.

/// A saved sign-in, without its password, which is read from the keychain
/// only as it goes into a page.
nonisolated struct Account: Hashable, Sendable {
    /// Where it was used, as `Site.key` has it.
    let host: String
    let user: String
}

/// What was just sent from a sign-in box, held until it is known whether it
/// worked: only a password that got someone in is worth offering to keep.
struct SentSignIn: Equatable {
    let host: String
    let user: String
    let password: String
    let at: Date

    /// Long enough for a slow sign-in to land; past that, the page moving on
    /// is not its doing.
    var isRecent: Bool { Date.now.timeIntervalSince(at) < 45 }
}

/// The saved accounts that could go in the sign-in box the caret is in, and
/// where that box is on the page (in points, from the page's top left).
struct PasswordChoices: Equatable {
    let tab: Tab.ID
    let site: String
    var spot: CGRect
    var accounts: [Account]
}

/// A sign-in that worked, with a password not yet kept.
struct PasswordOffer: Equatable {
    let tab: Tab.ID
    let account: Account
    let password: String
    /// This name has a password kept here already, a different one.
    let replaces: Bool
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

        var account: Account { Account(host: host, user: user) }
        var name: Name { Name(host: host, user: user, saved: saved) }
    }

    /// As kept in the file: a login without its password.
    nonisolated struct Name: Codable, Sendable {
        var host: String
        var user: String
        var saved: Date

        var account: Account { Account(host: host, user: user) }
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
        do {
            try FileManager.default.createDirectory(at: namesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(new).write(to: namesFile, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save the names of saved passwords: \(error)")
        }
    }

    private func store(_ new: [Login]) -> Bool {
        let sorted = new.sorted { $0.saved > $1.saved }
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

    /// The accounts for `host`'s site, its own host's first. From the file,
    /// without the keychain, unless the file has to be made again.
    func accounts(for host: String) -> [Account] {
        Site.matching(knownNames().map(\.account), host)
    }

    func password(for account: Account) -> String? {
        guard knownNames().contains(where: { $0.account == account }) else { return nil }
        return loadLogins()?.first { $0.account == account }?.password
    }

    /// Whether this name's password for the site is kept already, and whether
    /// one (another) is kept for it on this very host; nil when the keychain
    /// won't say, as then nothing could be kept either. A name not kept for
    /// the site at all needs no keychain to tell.
    func check(_ sent: SentSignIn) -> (known: Bool, replaces: Bool)? {
        let same = knownNames().map(\.account)
            .filter { $0.user == sent.user && Site.of($0.host) == Site.of(sent.host) }
        guard !same.isEmpty else { return (false, false) }
        guard let all = loadLogins() else { return nil }
        let known = all.contains { same.contains($0.account) && $0.password == sent.password }
        return (known, same.contains { $0.host == sent.host })
    }

    /// Adds them, or replaces those kept already; all or none.
    func save(_ new: [(Account, String)]) -> Bool {
        guard let loaded = loadLogins() else { return false }
        var all = kept(loaded)
        for (account, password) in new {
            all.removeAll { $0.account == account }
            all.append(Login(host: account.host, user: account.user, password: password, saved: .now))
        }
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

    /// The site a host belongs to: example.com for login.example.com, and
    /// example.co.uz for mail.example.co.uz.
    // ponytail: a few rules and a list of shared hosts in place of the public
    // suffix list; a suffix missing here only offers one site's accounts on
    // another's page, and still only once one of them is picked.
    static func of(_ host: String) -> String {
        let host = key(host)
        let labels = host.split(separator: ".").map(String.init)
        // An address (127.0.0.1, ::1) is a site of its own.
        if host.contains(":") || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        guard labels.count > 2 else { return host }
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

/// Passwords exported by another app, as CSV: Passwords (and Safari) write
/// Title, URL, Username, Password, …; Chrome name, url, username, password.
nonisolated enum PasswordsFile {
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

/// The page's side, in a script world of its own: the page can't see it, call
/// it, or talk to the browser in its name. Only the page's own frame, never
/// the frames inside it, which are often other sites'.
enum Passwords {
    static let world = WKContentWorld.world(name: "passwords")
    static let messages = Messages()

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.add(messages, contentWorld: world, name: "passwords")
    }

    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, ["http", "https"].contains(origin.protocol), !origin.host.isEmpty,
                  let page = message.webView, let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            (page.uiDelegate as? Browser)?.page(page, passwords: kind, body, host: Site.key(origin.host))
        }
    }

    /// Sites told never to ask about, by site.
    static var never: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "passwordsNeverSaved") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "passwordsNeverSaved") }
    }

    private static let source = #"""
        (() => {
            const post = (message) => window.webkit.messageHandlers.passwords.postMessage(message);
            const shown = (box) => {
                const r = box.getBoundingClientRect();
                return r.width > 0 && r.height > 0 && getComputedStyle(box).visibility !== 'hidden';
            };
            const usable = (box) => box instanceof HTMLInputElement && !box.disabled && !box.readOnly && shown(box);
            const isPassword = (box) => box instanceof HTMLInputElement && box.type === 'password' && usable(box);
            const isName = (box) => box instanceof HTMLInputElement && ['text', 'email', 'tel'].includes(box.type) && usable(box);
            const passwords = (scope = document) => [...scope.querySelectorAll('input[type=password]')].filter(isPassword);
            // The name that goes with a password box: the last one before it, in its form or else the page.
            const nameFor = (password) => {
                let name = null;
                for (const box of (password.form ?? document).querySelectorAll('input')) {
                    if (box === password) break;
                    if (isName(box)) name = box;
                }
                return name;
            };
            const passwordFor = (name) => passwords(name.form ?? document).find((box) => nameFor(box) === name) ?? null;
            // A name asked for on its own, before the password, as Google and Microsoft do.
            const nameAlone = (box) => box instanceof HTMLInputElement
                && (/username|email/.test(box.autocomplete) || box.type === 'email' || /user|login|email|identifier|account/i.test(`${box.name} ${box.id}`))
                && isName(box);
            const isField = (box) => isPassword(box) || (isName(box) && (nameAlone(box) || passwordFor(box) !== null));

            // The sign-in box the caret is in, and whether the browser lists accounts under it.
            let field = null;
            let listed = false;
            let filling = false;
            const spot = () => {
                const r = field.getBoundingClientRect();
                return { x: r.left, y: r.top, width: r.width, height: r.height };
            };
            const unlist = (kind) => {
                if (listed) post({ kind });
                listed = false;
            };

            const arrive = (box) => {
                if (filling) return;
                if (!isField(box)) {
                    field = null;
                    return unlist('blur');
                }
                field = box;
                // Filled already (by hand, or by picking): nothing to offer.
                const password = field.type === 'password' ? field : passwordFor(field);
                if ((password ?? field).value) return unlist('blur');
                listed = true;
                post({ kind: 'focus', spot: spot() });
            };
            addEventListener('focusin', (event) => arrive(event.target), true);
            // A click into the box that has the caret already (put there by the
            // page as it loaded, or after Esc put the list away) lists again.
            addEventListener('click', (event) => {
                if (event.isTrusted && event.target === document.activeElement && !listed) arrive(event.target);
            }, true);
            // The page put the caret in a box before this was here.
            if (document.activeElement instanceof HTMLInputElement) arrive(document.activeElement);
            // Only for a move within the page: the caret leaving the page
            // altogether (a click on the list of accounts) keeps it listed.
            addEventListener('focusout', () => setTimeout(() => {
                if (!field || !document.hasFocus() || document.activeElement === field) return;
                field = null;
                unlist('blur');
            }), true);
            addEventListener('input', (event) => {
                if (event.isTrusted && event.target === field) unlist('typing');
            }, true);
            let moving = false;
            const moved = () => {
                if (!listed || moving) return;
                moving = true;
                requestAnimationFrame(() => {
                    moving = false;
                    if (listed && field) post({ kind: 'move', spot: spot() });
                });
            };
            addEventListener('scroll', moved, true);
            addEventListener('resize', moved);

            // What the boxes hold as they are sent, said on every way of sending
            // them; the browser keeps the last.
            const sent = () => {
                const boxes = passwords();
                const filled = boxes.filter((box) => box.value);
                if (filled.length) {
                    // Of a new password and its confirmation, or an old one and a new: the last.
                    post({ kind: 'sent', user: nameFor(boxes[0])?.value ?? '', password: filled.at(-1).value });
                    watch();
                } else {
                    const name = [...document.querySelectorAll('input')].find((box) => box.value && nameAlone(box));
                    if (name) post({ kind: 'name', user: name.value });
                }
            };
            addEventListener('submit', sent, true);
            addEventListener('keydown', (event) => {
                if (event.key === 'Escape') unlist('typing');
                if (event.key === 'Enter' && event.isTrusted && event.target instanceof HTMLInputElement) sent();
            }, true);
            // Plenty of sign-in buttons are in no form, and never send one.
            addEventListener('click', (event) => {
                if (event.isTrusted && event.target.closest?.('button, input[type=submit], input[type=button], [role=button]')) sent();
            }, true);

            // A sign-in done without a new page shows it worked by taking its boxes
            // away, and keeping them away: the page quiet a moment with none left.
            let watching = null;
            const watch = () => {
                if (watching) return;
                let quiet = 0;
                const stop = () => {
                    watching?.disconnect();
                    watching = null;
                    clearTimeout(quiet);
                    clearTimeout(end);
                };
                watching = new MutationObserver(() => {
                    clearTimeout(quiet);
                    quiet = setTimeout(() => {
                        if (passwords().length) return;
                        stop();
                        post({ kind: 'gone' });
                    }, 1500);
                });
                watching.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'hidden'] });
                const end = setTimeout(stop, 45000);
            };

            window.nerdaAsksForPassword = () => passwords().length > 0;

            // As if typed: WebKit's own setter from this world, which the page's
            // frameworks don't watch, so the input event after it reads as news.
            const put = (box, value) => {
                box.focus();
                box.value = value;
                box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
                box.dispatchEvent(new Event('change', { bubbles: true }));
            };
            // Into the boxes the caret was in, and only on the site it was picked for.
            window.nerdaFill = (user, password, site) => {
                if (location.hostname.toLowerCase().replace(/^www\./, '') !== site) return false;
                const box = field?.isConnected ? field : passwords()[0];
                if (!box) return false;
                const passwordBox = box.type === 'password' ? box : passwordFor(box);
                const nameBox = box.type === 'password' ? nameFor(box) : box;
                listed = false;
                filling = true;
                try {
                    if (nameBox && user) put(nameBox, user);
                    if (passwordBox) put(passwordBox, password);
                } finally {
                    filling = false;
                }
                return true;
            };
        })();
        """#
}

extension Browser {
    /// What a page's sign-in boxes say, from `Passwords.Messages`.
    func page(_ page: WKWebView, passwords kind: String, _ body: [String: Any], host: String) {
        guard let tab = tab(for: page) else { return }
        switch kind {
        case "focus":
            guard let spot = Self.spot(body, on: page) else { return }
            choicesAsked += 1
            let asked = choicesAsked
            Task {
                let accounts = await vault.accounts(for: host)
                // Gone meanwhile: the caret moved on, or the tab did.
                guard asked == choicesAsked, tab.id == selectedID else { return }
                passwordChoices = accounts.isEmpty ? nil
                    : PasswordChoices(tab: tab.id, site: host, spot: spot, accounts: Array(accounts.prefix(6)))
            }
        case "move":
            guard passwordChoices?.tab == tab.id, let spot = Self.spot(body, on: page) else { return }
            passwordChoices?.spot = spot
        case "blur", "typing":
            hideChoices(on: tab)
        case "name":
            tab.nameSent = (host, body["user"] as? String ?? "", .now)
        case "sent":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            var user = body["user"] as? String ?? ""
            // The password step of a sign-in that asked for the name first.
            if user.isEmpty, let name = tab.nameSent, Site.of(name.host) == Site.of(host),
               Date.now.timeIntervalSince(name.at) < 600 { user = name.user }
            tab.signIn = SentSignIn(host: host, user: user, password: password, at: .now)
            hideChoices(on: tab)
        case "gone":
            guard let sent = tab.signIn, sent.isRecent, sent.host == host else { return }
            tab.signIn = nil
            offer(sent, on: tab)
        default:
            break
        }
    }

    /// A new page is in: if it came after a password went out, and asks for
    /// none itself, that sign-in worked. One that asks again was refused, or
    /// is the next step of the same sign-in.
    func signInLanded(on tab: Tab) {
        guard let sent = tab.signIn else { return }
        guard sent.isRecent, let page = tab.page else { return tab.signIn = nil }
        Task {
            let asks = try? await page.callAsyncJavaScript("return nerdaAsksForPassword()", contentWorld: Passwords.world) as? Bool
            guard asks == false, tab.signIn == sent else { return }
            tab.signIn = nil
            offer(sent, on: tab)
        }
    }

    private func offer(_ sent: SentSignIn, on tab: Tab) {
        guard !Passwords.never.contains(Site.of(sent.host)) else { return }
        Task {
            guard let (known, replaces) = await vault.check(sent), !known,
                  tabs.contains(where: { $0 === tab }) else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                passwordOffer = PasswordOffer(tab: tab.id, account: Account(host: sent.host, user: sent.user),
                                              password: sent.password, replaces: replaces)
            }
        }
    }

    func keepOfferedPassword() {
        guard let offer = passwordOffer else { return }
        dropPasswordOffer()
        Task {
            if await !vault.save([(offer.account, offer.password)]) {
                Self.tell("Couldn't save the password", "The keychain didn't take it.")
            }
        }
    }

    func neverSavePasswords() {
        guard let offer = passwordOffer else { return }
        Passwords.never.insert(Site.of(offer.account.host))
        dropPasswordOffer()
    }

    func dropPasswordOffer() {
        withAnimation(.easeOut(duration: 0.14)) { passwordOffer = nil }
    }

    /// One of the accounts listed, into the page it was listed on.
    func fill(_ account: Account) {
        guard let choices = passwordChoices, let page = tabs.first(where: { $0.id == choices.tab })?.page else { return }
        choicesAsked += 1
        passwordChoices = nil
        Task {
            // nil when the Mac was asked whether Nerda may read it, and said no.
            guard let password = await vault.password(for: account) else { return }
            _ = try? await page.callAsyncJavaScript(
                "return nerdaFill(user, password, site)",
                arguments: ["user": account.user, "password": password, "site": choices.site],
                contentWorld: Passwords.world
            )
            page.window?.makeFirstResponder(page)
        }
    }

    func forget(_ account: Account) {
        passwordChoices?.accounts.removeAll { $0 == account }
        if passwordChoices?.accounts.isEmpty == true { passwordChoices = nil }
        Task { await vault.forget(account) }
    }

    func hideChoices(on tab: Tab) {
        choicesAsked += 1
        if passwordChoices?.tab == tab.id { passwordChoices = nil }
    }

    /// File › Import Passwords: a file Passwords, Safari or Chrome exported.
    func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose the file of passwords exported from Passwords, Safari or Chrome."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return Self.tell("Couldn't read the file", "It isn't a text file.")
        }
        let logins = PasswordsFile.logins(in: text)
        guard !logins.isEmpty else {
            return Self.tell("No passwords in the file", "It has no URL, Username and Password columns.")
        }
        Task {
            guard await vault.save(logins) else {
                return Self.tell("Couldn't import the passwords", "The keychain didn't take them.")
            }
            Self.tell(
                logins.count == 1 ? "1 password imported" : "\(logins.count) passwords imported",
                "The file holds your passwords as plain text: delete it now that they are in the keychain."
            )
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Where the box is, from the page's CSS pixels to points.
    private static func spot(_ body: [String: Any], on page: WKWebView) -> CGRect? {
        guard let spot = body["spot"] as? [String: Double], let x = spot["x"], let y = spot["y"],
              let width = spot["width"], let height = spot["height"] else { return nil }
        let zoom = page.pageZoom
        return CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
    }
}

/// The accounts kept for the site, hanging from the sign-in box. A click puts
/// one in; right-click to forget it.
// ponytail: always below the box; one at the window's bottom edge would want it above.
struct PasswordChoicesView: View {
    let browser: Browser
    let choices: PasswordChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(choices.accounts, id: \.self) { account in
                ChoiceRow(account: account) { browser.fill(account) }
                    .contextMenu {
                        Button("Remove Saved Password") { browser.forget(account) }
                    }
            }
        }
        .padding(4)
        .frame(width: max(240, min(340, choices.spot.width)))
        .glassPanel(cornerRadius: 12)
    }

    private struct ChoiceRow: View {
        let account: Account
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.user.isEmpty ? "No user name" : account.user)
                            .foregroundStyle(Palette.ink)
                        Text(account.host)
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// After a sign-in that worked: keep its password?
struct PasswordOfferBar: View {
    let browser: Browser
    let offer: PasswordOffer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.replaces ? "Update the saved password?" : "Save this password?")
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.ink)
                Text(offer.account.user.isEmpty ? offer.account.host : "\(offer.account.user) on \(offer.account.host)")
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            // As wide as it says, up to a point: long names give way in the middle.
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 8)
            Button("Never for This Site", action: browser.neverSavePasswords)
            Button("Not Now", action: browser.dropPasswordOffer)
            Button(offer.replaces ? "Update" : "Save", action: browser.keepOfferedPassword)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .glassPanel(cornerRadius: 18)
    }
}
