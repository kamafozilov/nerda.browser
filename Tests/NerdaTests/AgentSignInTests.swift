import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents sign in with logins saved in Nerda (spec #119, ticket #147): the
/// login goes into the page, the agent is told only that it was filled, and
/// the password is in nothing it reads. The vault is the harness's own, in
/// memory: never the owner's, never the keychain.
@MainActor
struct AgentSignInTests {
    static let signInPage = """
        <title>Sign in</title>
        <form action="/done">
        <label>Email <input id=user type=email autocomplete=username></label>
        <label>Password <input id=password type=password autocomplete=current-password></label>
        <button>Sign in</button>
        </form>
        """

    /// The saved login is in the page's boxes, and no answer says the
    /// password: not sign_in's, not a snapshot's, not the text's.
    @Test func signInFillsTheSavedLoginWithoutShowingThePassword() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/login", Self.signInPage)
        let password = "Correct-horse-42"
        // The page is plain http (the test's server): a login last used over it.
        #expect(await harness.vault.save([(Account(host: "127.0.0.1", user: "kamron@example.com"), password)], clear: true))
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let signedIn = try await agent.call("sign_in", ["tab": "t1"])
        #expect(!signedIn.isError, "\(signedIn.text)")
        #expect(signedIn.text.contains("filled"), "\(signedIn.text)")
        #expect(signedIn.text.contains("kamron@example.com"), "\(signedIn.text)")

        let page = try #require(harness.agents?.tabs.first?.page)
        #expect(try await page.evaluateJavaScript("document.getElementById('user').value") as? String == "kamron@example.com")
        #expect(try await page.evaluateJavaScript("document.getElementById('password').value") as? String == password)

        let snapshot = try await agent.call("snapshot", ["tab": "t1", "full": true])
        let text = try await agent.call("text", ["tab": "t1"])
        let tabs = try await agent.call("tabs")
        for answer in [signedIn, snapshot, text, tabs] {
            #expect(!answer.text.contains(password), "\(answer.text)")
            #expect(!answer.text.contains("horse"), "\(answer.text)")
        }
        #expect(snapshot.text.contains("kamron@example.com"), "\(snapshot.text)")
    }

    /// With several logins saved for the site, the one the agent names goes
    /// in, though another was used last; without a name, the one used last. A name not saved fails,
    /// listing the names there are and no password.
    @Test func theNamedAccountIsTheOneFilled() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/login", Self.signInPage)
        let site = "127.0.0.1"
        #expect(await harness.vault.save([(Account(host: site, user: "work@example.com"), "Work-pass-1")], clear: true))
        #expect(await harness.vault.save([(Account(host: site, user: "home@example.com"), "Home-pass-2")], clear: true))
        await harness.vault.touch([Account(host: site, user: "home@example.com")])
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let page = try #require(harness.agents?.tabs.first?.page)
        func boxes() async throws -> [String] {
            try #require(try await page.evaluateJavaScript("[user.value, password.value]") as? [String])
        }

        let named = try await agent.call("sign_in", ["tab": "t1", "account": "work@example.com"])
        #expect(!named.isError, "\(named.text)")
        #expect(try await boxes() == ["work@example.com", "Work-pass-1"])
        #expect(named.text.contains("home@example.com"), "the others are named: \(named.text)")

        // Unnamed: the one used last, which filling it made the work login.
        try await page.evaluateJavaScript("user.value = ''; password.value = ''")
        let lastUsed = try await agent.call("sign_in", ["tab": "t1"])
        #expect(!lastUsed.isError, "\(lastUsed.text)")
        #expect(try await boxes() == ["work@example.com", "Work-pass-1"])

        let unknown = try await agent.call("sign_in", ["tab": "t1", "account": "nobody@example.com"])
        #expect(unknown.isError)
        #expect(unknown.text.contains("work@example.com") && unknown.text.contains("home@example.com"), "\(unknown.text)")
        for answer in [named, lastUsed, unknown] {
            #expect(!answer.text.contains("pass-"), "\(answer.text)")
        }
    }

    /// A page with no sign-in form, or a site with no saved login, fails
    /// with what to do instead: the user signs in by a Handoff.
    @Test func withNothingToFillTheAgentIsToldToHandOff() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let login = try await harness.pages.serve("/login", Self.signInPage)
        let home = try await harness.pages.serve("/home", "<title>Home</title><p>Welcome</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(home)])
        let noForm = try await agent.call("sign_in", ["tab": "t1"])
        #expect(noForm.isError)
        #expect(noForm.text.contains("no sign-in box"), "\(noForm.text)")

        _ = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(login)])
        let noLogin = try await agent.call("sign_in", ["tab": "t1"])
        #expect(noLogin.isError)
        #expect(noLogin.text.contains("no saved password") && noLogin.text.contains("handoff"), "\(noLogin.text)")
    }

    /// A sign-in that asks for the name on its own first, as Google's does,
    /// gets the name; the password goes in on the next step.
    @Test func aNameAskedAloneIsFilledFirst() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/identifier", """
            <title>Sign in</title>
            <form action="/password"><label>Email or phone <input id=user type=email name=identifier></label>
            <button>Next</button></form>
            """)
        #expect(await harness.vault.save([(Account(host: "127.0.0.1", user: "kamron@example.com"), "Step-pass-3")], clear: true))
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let answer = try await agent.call("sign_in", ["tab": "t1"])
        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("next step"), "\(answer.text)")
        #expect(!answer.text.contains("Step-pass"))
        let page = try #require(harness.agents?.tabs.first?.page)
        #expect(try await page.evaluateJavaScript("user.value") as? String == "kamron@example.com")
    }
}
