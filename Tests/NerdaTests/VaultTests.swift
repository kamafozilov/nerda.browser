import Foundation
import Testing
import WebKit
@testable import Nerda

/// A site's "Continue with Google" sends the page to Google with the site's
/// own address to answer to: the sign-in is kept for the site it started
/// from, whichever host the answer goes to.
@Test func socialSignInStartsFromTheSiteThatAsked() throws {
    let google = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=1&response_type=code"
        + "&redirect_uri=https%3A%2F%2Fwww.example.com%2Fauth%2Fcallback"))
    let started = try #require(SocialSignIn.start(google, from: [URL(string: "https://www.example.com/login")]))
    #expect(started.provider == "google" && started.host == "example.com" && !started.relay)

    // Google's pop-up answers the page itself, by its storage relay; the
    // pop-up has no page of the site's, its opener has.
    let popup = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=1"
        + "&redirect_uri=storagerelay%3A%2F%2Fhttps%2Fwww.notion.so%3Fid%3Dauth42"))
    let relayed = try #require(SocialSignIn.start(popup, from: [URL(string: "about:blank"), URL(string: "https://www.notion.so/login")]))
    #expect(relayed.host == "notion.so" && relayed.relay)
    // With no opener to tell, the answer's address says the site.
    #expect(SocialSignIn.start(popup, from: [popup])?.host == "notion.so")

    // A sign-in service the site uses answers on its own host: both count as back.
    let firebase = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=1"
        + "&redirect_uri=https://shop-app.firebaseapp.com/__/auth/handler"))
    let through = try #require(SocialSignIn.start(firebase, from: [URL(string: "https://app.shop.uz/")]))
    #expect(through.host == "app.shop.uz" && through.landing == ["shop.uz", "shop-app.firebaseapp.com"])

    let telegram = try #require(URL(string: "https://oauth.telegram.org/auth?bot_id=7&origin=https%3A%2F%2Fbozor.uz"))
    #expect(SocialSignIn.start(telegram, from: [nil])?.host == "bozor.uz")
    #expect(SocialSignIn.start(telegram, from: [nil])?.relay == true)
}

/// Signing in to Google itself, or to one of Google's own sites, is no sign-in
/// with a service: nothing is started.
@Test func signingInToTheServiceItselfStartsNothing() throws {
    let gmail = try #require(URL(string: "https://accounts.google.com/ServiceLogin?continue=https://mail.google.com/mail/"))
    #expect(SocialSignIn.start(gmail, from: [URL(string: "https://mail.google.com/")]) == nil)
    let own = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=1&redirect_uri=https://myaccount.google.com/"))
    #expect(SocialSignIn.start(own, from: [URL(string: "https://www.google.com/")]) == nil)
    let plain = try #require(URL(string: "http://accounts.google.com/o/oauth2/auth?client_id=1&redirect_uri=https://example.com/"))
    #expect(SocialSignIn.start(plain, from: [URL(string: "https://example.com/")]) == nil)
}

/// Back on the site is the sign-in done, unless the service answered with an
/// error (Cancel at Google); pages of the service, or of another site, are
/// still on the way.
@Test func socialSignInComesBackOrIsTurnedDown() throws {
    let pending = SocialSignIn.Pending(provider: "github", host: "example.com", landing: ["example.com"], relay: false, at: .now)
    let step = { (address: String) in SocialSignIn.step(pending, to: URL(string: address)!) }
    #expect(step("https://example.com/auth/github/callback?code=abc&state=1") == .back)
    #expect(step("https://app.example.com/") == .back)
    #expect(step("https://example.com/callback?error=access_denied&state=1") == .refused)
    #expect(step("https://example.com/callback#error=access_denied") == .refused)
    #expect(step("https://github.com/login/oauth/authorize?client_id=1") == .none)
    #expect(step("https://elsewhere.com/") == .none)
}

/// A sign-in with Google is kept apart from a password for the same name on
/// the site: a password sent there is new, and the sign-in is recalled (and
/// so not offered again) for its service only, under any name when none was seen.
@Test func socialSignInsAreKeptApartFromPasswords() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(#"[{"host":"example.com","user":"me@gmail.com","saved":0,"provider":"google"}]"#.utf8).write(to: file)
    let vault = Vault(service: "Nerda Tests \(UUID().uuidString)", names: file)
    let sent = SentSignIn(host: "example.com", user: "me@gmail.com", password: "secret", clear: false, at: .now)
    // Told without the keychain: no password is kept for the name.
    #expect(await vault.check(sent)?.known == false)
    #expect(await vault.recall(Account(host: "login.example.com", user: "me@gmail.com", provider: "google")))
    #expect(await vault.recall(Account(host: "example.com", user: "", provider: "google")))
    #expect(await !vault.recall(Account(host: "example.com", user: "me@gmail.com", provider: "github")))
    #expect(await !vault.recall(Account(host: "example.com", user: "other@gmail.com", provider: "google")))
    #expect(await vault.accounts(for: "example.com", clear: false) == [Account(host: "example.com", user: "me@gmail.com", provider: "google")])
}

/// A site's page sends the tab to Google, Google answers the site's own
/// address, and the site's page asks for no password: the sign-in is offered
/// over the tab, with the account picked at Google.
@MainActor @Test func aSignInWithGoogleIsOfferedOnceBack() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("[]".utf8).write(to: file)
    let browser = Browser(dataStore: .nonPersistent())
    browser.vault = Vault(service: "Nerda Tests \(UUID().uuidString)", names: file)
    let tab = Nerda.Tab()
    browser.add(tab)
    let page = tab.webView
    func load(_ html: String, at address: String) async throws {
        page.loadHTMLString(html, baseURL: URL(string: address)!)
        for _ in 0..<300 where page.isLoading || page.url?.absoluteString != address { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
    }
    try await load("<button>Continue with Google</button>", at: "https://www.example.com/login")
    try await load("<p>Choose an account</p>",
                   at: "https://accounts.google.com/o/oauth2/v2/auth?client_id=1&redirect_uri=https://www.example.com/cb")
    #expect(tab.social?.host == "example.com")
    tab.nameSent = ("accounts.google.com", "me@gmail.com", .now)
    try await load("<p>Welcome</p>", at: "https://www.example.com/cb?code=abc")
    for _ in 0..<100 where browser.passwordOffer == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(browser.passwordOffer?.tab == tab.id)
    #expect(browser.passwordOffer?.account == Account(host: "example.com", user: "me@gmail.com", provider: "google"))
    #expect(tab.social == nil)
}

/// A made-up password is three groups of six with a capital and a digit, and
/// strong; the check finds the weak, and those used on more than one site,
/// though not one used on two hosts of the same site.
@Test func passwordsAreMadeStrongAndCheckedForReuse() {
    for _ in 0..<50 {
        let made = PasswordCheck.strong()
        let groups = made.split(separator: "-")
        #expect(groups.count == 3 && groups.allSatisfy { $0.count == 6 })
        #expect(made.count(where: \.isUppercase) == 1 && made.contains(where: \.isNumber))
        #expect(PasswordCheck.strength(made) == .strong)
    }
    #expect(PasswordCheck.strength("Password1") == .weak)
    #expect(PasswordCheck.strength("hunter2") == .weak)
    #expect(PasswordCheck.strength("aaaaaaaaaaaaaaaaaaaa") == .weak)
    #expect(PasswordCheck.strength("correcthorse") == .fair)

    let login = { (host: String, user: String, password: String, provider: String?) in
        Vault.Login(host: host, user: user, password: password, saved: .now, provider: provider)
    }
    let issues = PasswordCheck.issues([
        login("bank.uz", "me", "Shared-pass-2024", nil),
        login("shop.uz", "me", "Shared-pass-2024", nil),
        login("mail.example.com", "me", "Own-pass-of-example", nil),
        login("example.com", "me", "Own-pass-of-example", nil),
        login("old.uz", "me", "123456", nil),
        login("notion.so", "me@gmail.com", "", "google"),
    ])
    #expect(issues.reused == [Account(host: "bank.uz", user: "me"), Account(host: "shop.uz", user: "me")])
    #expect(issues.weak == [Account(host: "old.uz", user: "me")])
}

/// Exported passwords read in again as they were, commas, quotes and line
/// breaks included; a sign-in with a service has no password, and stays out.
@Test func exportedPasswordsReadInAgain() {
    let logins = [
        Vault.Login(host: "bank.uz", user: "me", password: "p,a\"ss\nword", saved: .now, note: "PIN, \"1234\""),
        Vault.Login(host: "router.lan", user: "admin", password: "admin1", saved: .now, clear: true),
        Vault.Login(host: "notion.so", user: "me@gmail.com", password: "", saved: .now, provider: "google"),
    ]
    let csv = PasswordsFile.csv(logins)
    #expect(csv.hasPrefix("name,url,username,password,note\n"))
    #expect(csv.contains("http://router.lan/"))
    let read = Dictionary(uniqueKeysWithValues: PasswordsFile.logins(in: csv).map { ($0.0, $0.1) })
    #expect(read == [Account(host: "bank.uz", user: "me"): "p,a\"ss\nword", Account(host: "router.lan", user: "admin"): "admin1"])
    #expect(PasswordsFile.rows(csv)[1].last == "PIN, \"1234\"")
}
