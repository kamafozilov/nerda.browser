import SwiftUI
import WebKit

// Sign in with Google, Apple, GitHub…: a site sends you to the service, the
// service asks which account (or nothing, if you said yes before), and sends
// you back signed in. No password goes through the site, so none is offered;
// what is worth keeping is which service, and which account on it, opened
// which site. Kept in the Vault beside the passwords (`Account.provider`),
// listed under the site's sign-in box, and a pick presses the site's own
// button for that service.

nonisolated enum SocialSignIn {
    struct Provider: Identifiable, Sendable {
        /// As `Account.provider` keeps it.
        let id: String
        let name: String
        /// Where its sign-in pages are.
        let hosts: Set<String>
        /// The site its icon comes from.
        let icon: String
    }

    static let providers = [
        Provider(id: "google", name: "Google", hosts: ["accounts.google.com"], icon: "google.com"),
        Provider(id: "apple", name: "Apple", hosts: ["appleid.apple.com"], icon: "apple.com"),
        Provider(id: "github", name: "GitHub", hosts: ["github.com"], icon: "github.com"),
        Provider(id: "microsoft", name: "Microsoft", hosts: ["login.microsoftonline.com", "login.live.com"], icon: "microsoft.com"),
        Provider(id: "facebook", name: "Facebook", hosts: ["facebook.com", "m.facebook.com"], icon: "facebook.com"),
        Provider(id: "x", name: "X", hosts: ["x.com", "twitter.com", "api.twitter.com", "api.x.com"], icon: "x.com"),
        Provider(id: "linkedin", name: "LinkedIn", hosts: ["linkedin.com"], icon: "linkedin.com"),
        Provider(id: "gitlab", name: "GitLab", hosts: ["gitlab.com"], icon: "gitlab.com"),
        Provider(id: "discord", name: "Discord", hosts: ["discord.com"], icon: "discord.com"),
        Provider(id: "slack", name: "Slack", hosts: ["slack.com"], icon: "slack.com"),
        Provider(id: "telegram", name: "Telegram", hosts: ["oauth.telegram.org"], icon: "telegram.org"),
        Provider(id: "yandex", name: "Yandex", hosts: ["oauth.yandex.ru", "oauth.yandex.com"], icon: "yandex.ru"),
    ]

    static func provider(_ id: String?) -> Provider? {
        providers.first { $0.id == id }
    }

    /// A sign-in with a service under way in a tab: from the request that
    /// went to the service until the tab is back on the site.
    struct Pending: Equatable {
        let provider: String
        /// Where it was started from, as `Site.key` has it: what it is kept under.
        let host: String
        /// The sites that count as back: the one it started from, and the one
        /// the service was told to answer to, when that is another (a sign-in
        /// service the site uses, as Firebase's).
        let landing: Set<String>
        /// The service answers the page that asked without a page of the
        /// site's own (Google's pop-up, Telegram's): the pop-up closing by
        /// itself is the sign-in done.
        let relay: Bool
        let at: Date
        /// The service sent the tab back to the site, without an error.
        var returned = false

        /// Long enough to choose an account and say yes, with a code from the phone.
        var isRecent: Bool { Date.now.timeIntervalSince(at) < 600 }
    }

    /// What a navigation does for a sign-in under way.
    enum Step: Equatable { case none, back, refused }

    /// A request asking a service who you are for a site: an OAuth or
    /// OpenID request names the site that asked (`client_id`), and where to
    /// answer (`redirect_uri`); Telegram's, the site (`origin`). The site is
    /// the first of `origins` that is a website and not the service: the
    /// page it is sent from, then the opener of the pop-up it opens in.
    static func start(_ url: URL, from origins: [URL?]) -> Pending? {
        guard url.scheme == "https", let host = url.host().map(Site.key),
              let provider = providers.first(where: { $0.hosts.contains(host) }),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard value("client_id") ?? value("bot_id") ?? value("oauth_token") != nil else { return nil }
        let own = Site.of(host)
        let answer = value("redirect_uri") ?? value("origin")
        let answered = answer.flatMap(Self.host(of:))
        let from = origins.lazy.compactMap { $0.flatMap { ["http", "https"].contains($0.scheme) ? $0.host() : nil } }
            .map(Site.key).first { Site.of($0) != own }
        guard let site = [from, answered].compactMap(\.self).first(where: { Site.of($0) != own }) else { return nil }
        let relay = answer?.hasPrefix("storagerelay://") == true || provider.id == "telegram"
            || value("response_mode") == "web_message"
        let landing = Set([from, answered].compactMap(\.self).map(Site.of).filter { $0 != own })
        return Pending(provider: provider.id, host: site, landing: landing, relay: relay, at: .now)
    }

    /// Where a navigation of the tab goes, for the sign-in under way: still
    /// at the service, or somewhere on the way, is nothing yet.
    static func step(_ pending: Pending, to url: URL) -> Step {
        guard let host = url.host().map(Site.key), pending.landing.contains(Site.of(host)),
              provider(pending.provider)?.hosts.contains(host) != true else { return .none }
        // Turned down at the service: it answers with the error, and no account.
        let answer = [url.query(), url.fragment()].compactMap(\.self).joined(separator: "&")
        let refused = answer.split(separator: "&").contains { $0.hasPrefix("error=") }
        return refused ? .refused : .back
    }

    /// The host in an answer address: `https://site/callback`, or Google's
    /// pop-up's `storagerelay://https/site?id=…`.
    static func host(of answer: String) -> String? {
        if answer.hasPrefix("storagerelay://") {
            let parts = answer.dropFirst("storagerelay://".count).split(separator: "/")
            guard parts.count > 1 else { return nil }
            let host = parts[1].split(separator: "?")[0].split(separator: ":")[0]
            return host.isEmpty ? nil : Site.key(String(host))
        }
        guard let url = URL(string: answer), ["http", "https"].contains(url.scheme), let host = url.host(), !host.isEmpty
        else { return nil }
        return Site.key(host)
    }

    /// Google's list of accounts names each, and none is typed: the one
    /// clicked is the account, said as a name sent on its own (`nameSent`).
    /// Run in every frame; returns at once on any other host.
    static let chooser = #"""
        (() => {
            if (location.hostname !== 'accounts.google.com') return;
            addEventListener('click', (event) => {
                if (!event.isTrusted) return;
                const chosen = event.target.closest?.('[data-identifier], [data-email]');
                const user = chosen?.getAttribute('data-identifier') || chosen?.getAttribute('data-email');
                if (user?.includes('@')) window.webkit.messageHandlers.passwords.postMessage({ kind: 'name', user });
            }, true);
        })();
        """#

    /// Part of the passwords' script (`Passwords.source`): presses the
    /// site's own button for a service, the one whose words are fewest of
    /// those naming it ("Continue with Google" over a paragraph about Google),
    /// on the site it was listed for only.
    static let button = #"""
        window.nerdaSignInWith = (name, site) => {
            if (location.hostname.toLowerCase().replace(/^www\./, '') !== site) return false;
            const named = new RegExp(`(^|\\W)${name}(\\W|$)`, 'i');
            const words = (box) => [box.innerText, box.getAttribute('aria-label'), box.title, box.value,
                ...[...box.querySelectorAll('img[alt]')].map((image) => image.alt)].filter(Boolean).join(' ').trim();
            const button = [...document.querySelectorAll('button, a[href], [role=button], input[type=submit], input[type=button]')]
                .filter((box) => !box.disabled && shown(box) && named.test(words(box)))
                .sort((a, b) => words(a).length - words(b).length)[0];
            if (!button) return false;
            button.scrollIntoView({ block: 'center' });
            button.focus();
            button.click();
            return true;
        };
        """#
}

extension Browser {
    /// Each navigation of a tab's page that goes ahead: the request to a
    /// service starts a sign-in, and the service's answer to the site brings
    /// it back, or turns it down.
    func watchSocialSignIn(to url: URL?, on tab: Tab) {
        guard let url, Passwords.offers else { return }
        let opener = tab.opener.flatMap { id in tabs.first { $0.id == id } }
        // The service's own next steps ask again (Google's do): the sign-in
        // under way goes on, with the site it was started from.
        if let started = SocialSignIn.start(url, from: [tab.committed ?? tab.url, opener?.committed ?? opener?.url]),
           tab.social.map({ $0.provider != started.provider || $0.returned || !$0.isRecent }) ?? true {
            tab.social = started
            return
        }
        guard var pending = tab.social else { return }
        guard pending.isRecent else { return tab.social = nil }
        switch SocialSignIn.step(pending, to: url) {
        case .none: break
        case .refused: tab.social = nil
        case .back:
            pending.returned = true
            tab.social = pending
        }
    }

    /// A page is in, after the service answered the site, and not the
    /// service's: one that asks for no password (as a site that wants one
    /// more step would) is the sign-in done. It may be on another of the
    /// site's hosts than the answer was (chatgpt.com after auth.openai.com).
    func socialLanded(on tab: Tab) {
        guard let pending = tab.social, pending.returned, let page = tab.page, let host = page.url?.host().map(Site.key),
              SocialSignIn.provider(pending.provider)?.hosts.contains(host) == false else { return }
        tab.social = nil
        Task {
            let asks = try? await page.callAsyncJavaScript("return nerdaAsksForPassword()", contentWorld: Passwords.world) as? Bool
            guard asks == false else { return }
            offerSocial(pending, from: tab)
        }
    }

    /// A pop-up closed by its own page: one that answered the site itself,
    /// or after the site's page in it had the answer.
    func socialPopupClosed(_ tab: Tab) {
        guard tab.opener != nil, let pending = tab.social, pending.isRecent, pending.relay || pending.returned else { return }
        tab.social = nil
        offerSocial(pending, from: tab)
    }

    /// A sign-in with a service picked under the site's sign-in box: the
    /// site's own button for that service, pressed, as a click of yours, so
    /// the service's pop-up may open.
    func signIn(with provider: SocialSignIn.Provider, as account: Account, _ choices: PasswordChoices, on page: WKWebView) {
        Task {
            let pressed = try? await page.callAsyncJavaScript(
                "return nerdaSignInWith(name, site)",
                arguments: ["name": provider.name, "site": choices.site],
                in: choices.frame,
                contentWorld: Passwords.world
            ) as? Bool
            guard pressed == true else {
                return Self.tell("Couldn't find the \(provider.name) button",
                                 "Sign in with \(provider.name) on this page yourself: Nerda didn't find the button for it.")
            }
            await vault.touch([account])
        }
    }

    /// Keep it? Asked over the site's tab (the pop-up's opener), with the
    /// account chosen at the service when it was seen. Asked once: a sign-in
    /// with the service kept for the site already is counted as used.
    private func offerSocial(_ pending: SocialSignIn.Pending, from tab: Tab) {
        guard !Passwords.never.contains(Site.of(pending.host)), Extensions.shared.passwordSavingTakenBy == nil,
              let provider = SocialSignIn.provider(pending.provider) else { return }
        let target = tab.opener.flatMap { id in tabs.first { $0.id == id } } ?? tab
        let named = [tab.nameSent, target.nameSent].compactMap(\.self).first {
            provider.hosts.contains(Site.key($0.host)) && Date.now.timeIntervalSince($0.at) < 600
        }
        let account = Account(host: pending.host, user: named?.user ?? "", provider: provider.id)
        Task {
            guard await !vault.recall(account), tabs.contains(where: { $0 === target }),
                  passwordOffer?.tab != target.id else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                passwordOffer = PasswordOffer(tab: target.id, account: account, password: "", clear: false, replaces: false)
            }
        }
    }
}
