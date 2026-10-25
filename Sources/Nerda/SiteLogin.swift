import AppKit
import WebKit

/// A site's own sign-in (Basic, Digest, NTLM, Kerberos), as WebKit asks
/// Browser for it (`webView(_:respondTo:)`).
extension Browser {
    /// The password WebKit offers for a sign-in, or the one the Mac keeps for
    /// the place; none once it has been turned down, which would only go
    /// round again.
    nonisolated static func savedLogin(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.previousFailureCount == 0 else { return nil }
        return [challenge.proposedCredential, URLCredentialStorage.shared.defaultCredential(for: challenge.protectionSpace)]
            .lazy.compactMap(\.self).first(where: \.hasPassword)
    }

    /// Safari's sheet for a site's own sign-in, over its page once its tab is
    /// on screen: filled in with the account saved for that very host and
    /// port (`loginKey`), or after a wrong password, with the name just tried.
    /// A password that gets in is offered to keep, as one typed into a page
    /// is (`signInLanded`); a proxy's is neither filled in nor offered.
    /// Cancelled, the page shows the site's own answer to no sign-in; the
    /// sheet goes by itself once the tab has gone on without it.
    func askForLogin(_ challenge: URLAuthenticationChallenge, on webView: WKWebView) async -> URLCredential? {
        let space = challenge.protectionSpace
        let key = Self.loginKey(for: space)
        let clear = space.protocol == NSURLProtectionSpaceHTTP
        // Asked again: the last try was turned down, and is nothing to keep.
        let tried = tab(for: webView)?.signIn
        tab(for: webView)?.signIn = nil
        guard await window(showing: webView) != nil else { return nil }
        var user = ""
        var password = ""
        if challenge.previousFailureCount > 0 {
            user = challenge.proposedCredential?.user ?? (key != nil && tried?.host == key ? tried?.user : nil) ?? ""
        } else if Passwords.fills, let key,
                  let account = await vault.accounts(for: key, clear: clear).first(where: { $0.host == key && $0.provider == nil }) {
            user = account.user
            password = await vault.password(for: account) ?? ""
        }

        let name = NSTextField(string: user)
        let secret = NSSecureTextField(string: password)
        name.setAccessibilityLabel("User Name")
        secret.setAccessibilityLabel("Password")
        for field in [name, secret] { field.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        let form = NSGridView(views: [[NSTextField(labelWithString: "User Name:"), name],
                                      [NSTextField(labelWithString: "Password:"), secret]])
        form.rowAlignment = .firstBaseline
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 8
        form.frame.size = form.fittingSize

        let (title, note) = Self.loginText(for: space)
        let answer = await ask(title, note, over: webView, buttons: ["Log In", "Cancel"],
                               accessory: form, focus: user.isEmpty ? name : secret, whileThere: true)
        guard answer == .alertFirstButtonReturn else { return nil }
        if let key, !secret.stringValue.isEmpty, let tab = tab(for: webView) {
            tab.signIn = SentSignIn(host: key, user: name.stringValue, password: secret.stringValue, clear: clear, at: .now)
        }
        return URLCredential(user: name.stringValue, password: secret.stringValue, persistence: .forSession)
    }

    /// Where a site's sign-in is saved and filled in from: its host, with
    /// the port when it isn't the scheme's own, as two servers of one site
    /// (a router's pages and its printer's) each have their own. None for a
    /// proxy, whose password is not a site's to keep or offer.
    nonisolated static func loginKey(for space: URLProtectionSpace) -> String? {
        space.isProxy() ? nil : Site.key(place(of: space))
    }

    /// The host, with its port when it isn't the scheme's own.
    private nonisolated static func place(of space: URLProtectionSpace) -> String {
        guard space.port > 0, ["http": 80, "https": 443][space.protocol?.lowercased() ?? ""] != space.port else { return space.host }
        return "\(space.host):\(space.port)"
    }

    /// What the sign-in sheet says: where you log in, and whether the
    /// password goes there in the clear.
    nonisolated static func loginText(for space: URLProtectionSpace) -> (title: String, note: String) {
        let place = space.isProxy() ? "proxy \(place(of: space))" : place(of: space)
        return ("Log in to \(place)", space.receivesCredentialSecurely
                ? "Your login information will be sent securely."
                : "Your login information will not be sent securely.")
    }
}
