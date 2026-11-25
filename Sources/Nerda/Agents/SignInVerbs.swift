import Foundation
import WebKit

/// Signing in with a login the owner saved in Nerda: the agent names the
/// account, Nerda fills it, and the agent never sees the password.
nonisolated extension AgentVerb {
    static let signInVerbs: [AgentVerb] = [signIn]

    static let signIn = AgentVerb(
        name: "sign_in",
        summary: """
            Fill a login the user saved in Nerda into the sign-in form on an Agent tab's page: its name, \
            and its password, which you never see. Answers only what was filled; then press the form's \
            sign-in button. With several saved for the site, name one with account (default: the one \
            used last). Without a saved login, ask the user with handoff (step sign_in).
            """,
        arguments: [
            .tab,
            .string("account", "The saved login's user name, such as kamron@example.com (default: the one used last on the site)",
                    required: false),
        ]
    ) { call in
        try await AgentSignIn.fill(try call.tab(), account: call.optionalString("account"))
    }
}

/// How `sign_in` finds the page's sign-in form and fills it: with the same
/// page script as the owner's picks from the list under a sign-in box
/// (`Passwords`), in Nerda's own world, which the page and the agents'
/// worlds can't read. The password goes from the vault into that world and
/// nowhere else: no answer, and no error, carries it.
@MainActor
enum AgentSignIn {
    /// A frame with a sign-in form: nil for the main frame.
    private struct Form {
        let frame: WKFrameInfo?
        /// As `Site.key` has it.
        let host: String
        /// It came over plain http.
        let clear: Bool
        /// What it asks for: "password" (with the name or not), or "name" alone.
        let asks: String
    }

    static func fill(_ agentTab: AgentTab, account wanted: String?) async throws -> String {
        let ref = agentTab.ref
        guard let page = agentTab.tab.page else {
            throw AgentError(.failed, "Tab \(ref) has no page loaded. Open the site's sign-in page in it with navigate.")
        }
        guard let form = await form(on: page) else {
            throw AgentError(.failed, """
                \(ref)'s page has no sign-in box to fill. Go to the site's sign-in page first, or ask the user \
                to sign in with handoff (step sign_in).
                """)
        }
        let vault = agentTab.agents.browser.vault
        let accounts = await vault.accounts(for: form.host, clear: form.clear).filter { $0.provider == nil }
        guard let account = try choose(wanted, from: accounts, site: form.host) else {
            throw AgentError(.failed, """
                Nerda has no saved password for \(form.host). Ask the user to sign in with handoff (step sign_in).
                """)
        }
        // nil when the Mac asked whether Nerda may read it, and was told no.
        guard let password = await vault.password(for: account) else {
            throw AgentError(.failed, "Nerda couldn't read the saved password from the keychain. Ask the user to sign in with handoff (step sign_in).")
        }
        let filled = try? await page.callAsyncJavaScript(
            "return nerdaFill(user, password, site, secure)",
            arguments: ["user": account.user, "password": password, "site": form.host, "secure": !form.clear],
            in: form.frame, contentWorld: Passwords.world
        ) as? Bool
        guard filled == true else {
            throw AgentError(.failed, "The sign-in form on \(ref) changed before Nerda could fill it. Take a snapshot and call sign_in again.")
        }
        await vault.touch([account])

        var lines = [form.asks == "password"
            ? "filled: the saved login \(account.user) for \(form.host), its name and password. Press the form's sign-in button to go on."
            : "filled: \(account.user), the saved login's name for \(form.host). The password comes on the next step: press the form's button, then call sign_in again."]
        let others = accounts.filter { $0 != account }.map(\.user)
        if !others.isEmpty {
            lines.append("Other saved logins for the site: \(others.joined(separator: ", ")) (name one with account).")
        }
        return (lines + [""] + AgentPage.header(agentTab)).joined(separator: "\n")
    }

    /// The account named, by its user name (case aside), or the one used
    /// last; nil when there is none. An unknown name fails, naming those
    /// there are.
    private static func choose(_ wanted: String?, from accounts: [Account], site: String) throws -> Account? {
        guard let wanted = wanted?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else { return accounts.first }
        if let found = accounts.first(where: { $0.user.caseInsensitiveCompare(wanted) == .orderedSame }) { return found }
        guard !accounts.isEmpty else { return nil }
        throw AgentError(.invalid, """
            Nerda has no saved login named \(wanted) for \(site). Saved: \(accounts.map(\.user).joined(separator: ", ")).
            """)
    }

    /// The frame whose sign-in form to fill: the first, main frame first,
    /// asking for a password, else the first asking for a name alone.
    private static func form(on page: WKWebView) async -> Form? {
        let tree = await AgentPage.frames(of: page)
        let frames: [(info: WKFrameInfo?, origin: (scheme: String, host: String)?)] = tree.map {
            $0.all.map { frame in
                (frame.info.isMainFrame ? nil : frame.info, (frame.info.securityOrigin.protocol, frame.info.securityOrigin.host))
            }
        } ?? [(nil, page.url.flatMap { url in url.host().map { (url.scheme ?? "", $0) } })]
        var found: [Form] = []
        for (info, origin) in frames {
            guard let origin, ["http", "https"].contains(origin.scheme), !origin.host.isEmpty else { continue }
            // The rest of the passwords script, as the frame would send for
            // once a box is gone to; it does nothing where it is in already.
            let asks = try? await page.callAsyncJavaScript(
                Passwords.source + "\nreturn window.nerdaSignInAsks?.() ?? null;",
                in: info, contentWorld: Passwords.world
            ) as? String
            guard let asks else { continue }
            let form = Form(frame: info, host: Site.key(origin.host), clear: origin.scheme == "http", asks: asks)
            if asks == "password" { return form }
            found.append(form)
        }
        return found.first
    }
}
