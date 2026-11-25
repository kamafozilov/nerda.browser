import Foundation
import Testing
import WebKit
@testable import Nerda

/// A payment an agent presses waits for the owner's Touch ID (spec #119,
/// ticket #148): a pay button, or sending a form that holds card fields,
/// whether pressed with click, press or from eval. The approval fits that
/// element and that amount only. Sending and deleting go through as ever.
/// The owner here is a `TestPayer`: no sheet or Touch ID prompt shows.
@MainActor
struct AgentPaymentTests {
    /// The press waits: the agent hears needs_user, the owner is shown
    /// the payment and its amount, and nothing is pressed until they
    /// approve it; then the press goes through.
    @Test func aPayButtonWaitsForApprovalAndGoesThroughOnlyAfterIt() async throws {
        let payer = TestPayer()
        let harness = try AgentHarness(approvePayment: payer.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/checkout", Self.shop("""
            <p>Total: $12.00</p>
            <button id=pay>Pay now</button>
            """))
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let pay = try #require(try await ref(of: #"button "Pay now""#, agent))

        let held = try await agent.call("click", ["tab": "t1", "ref": .string(pay)])

        #expect(!held.isError, "needs_user is no failure: \(held.text)")
        #expect(held.text.contains("needs_user"), "\(held.text)")
        #expect(held.text.contains("Touch ID"), "\(held.text)")
        #expect(try await clicks(harness) == [])
        let card = try #require(payer.shown.first)
        #expect(card.asker == "Claude")
        #expect(card.amounts == ["$12.00"])
        #expect(card.what.contains("Pay now"), "\(card.what)")
        #expect(harness.server.owner.waiting.count == 1)
        #expect(harness.notifier.posted.contains { $0.title == "Claude wants to pay" })

        let call = Task { try await agent.call("click", ["tab": "t1", "ref": .string(pay)], progressToken: "p1") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await clicks(harness) == [])
        payer.verdict = true
        let paid = try await call.value

        #expect(!paid.isError, "\(paid.text)")
        #expect(paid.text.hasPrefix(#"clicked \#(pay) button "Pay now""#), "\(paid.text)")
        #expect(try await clicks(harness) == ["trusted pay"])
        #expect(payer.shown.count == 1)
        #expect(harness.server.owner.waiting.isEmpty)
    }

    /// A form holding card fields is a payment however it is sent: its
    /// button, whatever it says, or Enter in one of its fields. Declined,
    /// the agent is told so and the form isn't sent.
    @Test func submittingAFormWithCardFieldsIsAPayment() async throws {
        let payer = TestPayer()
        let harness = try AgentHarness(approvePayment: payer.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/card", Self.shop("""
            <form action="/paid" method=get>
              <label>Name on card <input name=holder></label>
              <label>Card <input name=number autocomplete=cc-number></label>
              <label>CVC <input name=code></label>
              <p>You'll be charged 49,90 €</p>
              <button id=go>Continue</button>
            </form>
            """))
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let go = try #require(try await ref(of: #"button "Continue""#, agent))
        let holder = try #require(try await ref(of: #"textbox "Name on card""#, agent))

        let clicked = try await agent.call("click", ["tab": "t1", "ref": .string(go)])
        #expect(clicked.text.contains("needs_user"), "\(clicked.text)")
        #expect(payer.shown.last?.amounts == ["49,90 €"])
        payer.verdict = false
        try await waitFor { harness.server.owner.waiting.isEmpty }
        let declined = try await agent.call("click", ["tab": "t1", "ref": .string(go)])
        #expect(declined.isError)
        #expect(declined.text.contains("didn't approve"), "\(declined.text)")

        let pressed = try await agent.call("press", ["tab": "t1", "key": "Enter", "ref": .string(holder)])

        #expect(pressed.text.contains("needs_user"), "\(pressed.text)")
        #expect(payer.shown.count == 2)
        #expect(try await clicks(harness) == [])
        #expect(harness.pages.requests(for: "/paid").isEmpty)
    }

    /// eval can't press a payment by any of the usual ways: it is refused,
    /// told to use click, and nothing is pressed or sent. What doesn't pay
    /// it presses as ever.
    @Test func aPaymentPressedFromEvalIsHeldToo() async throws {
        let payer = TestPayer()
        let harness = try AgentHarness(approvePayment: payer.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/eval", Self.shop("""
            <p>Total: 300 000 so'm</p>
            <button id=pay onclick="event.preventDefault()">To‘lash</button>
            <form id=card action="/paid" method=get onsubmit="clicks.push('submitted'); return false">
              <input name=cardnumber placeholder="Card number">
              <input id=field name=holder>
              <input type=submit id=next value="Next">
            </form>
            <button id=send>Send</button>
            """))
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let ways = [
            "document.querySelector('#pay').click()",
            "document.querySelector('#pay').dispatchEvent(new MouseEvent('click', { bubbles: true }))",
            "document.querySelector('#pay').firstChild.parentElement.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))",
            "document.querySelector('#card').requestSubmit()",
            "document.querySelector('#card').submit()",
            "HTMLFormElement.prototype.submit.call(document.querySelector('#card'))",
            "document.querySelector('#card').dispatchEvent(new SubmitEvent('submit', { cancelable: true }))",
            "document.querySelector('#field').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))",
            "document.querySelector('#next').click()",
        ]
        for code in ways {
            let refused = try await agent.call("eval", ["tab": "t1", "script": .string(code)])
            #expect(refused.isError, "\(code): \(refused.text)")
            #expect(refused.text.contains("payment"), "\(code): \(refused.text)")
            #expect(refused.text.contains("click"), "\(code): \(refused.text)")
        }
        #expect(try await clicks(harness) == [])
        #expect(harness.pages.requests(for: "/paid").isEmpty)
        #expect(payer.shown.isEmpty)

        let sent = try await agent.call("eval", ["tab": "t1", "script": "document.querySelector('#send').click(); return 'sent'"])
        #expect(!sent.isError, "\(sent.text)")
        #expect(try await clicks(harness) == ["script send"])
    }

    /// An approval is for the element pressed and the amount shown: another
    /// pay button, or the same one once the amount changed, waits for the
    /// owner again. The one approved goes through on its own.
    @Test func anApprovalDoesntCarryOverToAnotherElementOrAmount() async throws {
        let payer = TestPayer()
        let harness = try AgentHarness(approvePayment: payer.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/plans", Self.shop("""
            <section><p id=price>Basic: $10.00</p><button id=basic>Buy Basic</button></section>
            <section><p>Pro: $20.00</p><button id=pro>Buy Pro</button></section>
            """))
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let basic = try #require(try await ref(of: #"button "Buy Basic""#, agent))
        let pro = try #require(try await ref(of: #"button "Buy Pro""#, agent))

        #expect(try await agent.call("click", ["tab": "t1", "ref": .string(basic)]).text.contains("needs_user"))
        #expect(payer.shown.last?.amounts == ["$10.00"])
        payer.verdict = true
        try await waitFor { harness.server.owner.waiting.isEmpty }

        let other = try await agent.call("click", ["tab": "t1", "ref": .string(pro)])
        #expect(other.text.contains("needs_user"), "\(other.text)")
        #expect(payer.shown.count == 2)
        #expect(payer.shown.last?.amounts == ["$20.00"])

        _ = try await page(harness).callAsyncJavaScript("price.textContent = 'Basic: $15.00'", contentWorld: .page)
        let dearer = try await agent.call("click", ["tab": "t1", "ref": .string(basic)])
        #expect(dearer.text.contains("needs_user"), "\(dearer.text)")
        #expect(payer.shown.count == 3)
        #expect(payer.shown.last?.amounts == ["$15.00"])
        #expect(try await clicks(harness) == [])

        // Back at the amount approved, the approval fits, once.
        _ = try await page(harness).callAsyncJavaScript("price.textContent = 'Basic: $10.00'", contentWorld: .page)
        let bought = try await agent.call("click", ["tab": "t1", "ref": .string(basic)])
        #expect(!bought.isError, "\(bought.text)")
        #expect(bought.text.hasPrefix("clicked \(basic)"), "\(bought.text)")
        #expect(try await clicks(harness) == ["trusted basic"])
        #expect(payer.shown.count == 3)
        let again = try await agent.call("click", ["tab": "t1", "ref": .string(basic)])
        #expect(again.text.contains("needs_user"), "\(again.text)")
        #expect(payer.shown.count == 4)
    }

    /// Send and delete buttons, and links about payments that pay nothing,
    /// go through at once; pay buttons in Nerda's other languages wait.
    @Test func sendAndDeleteButtonsAreNotHeld() async throws {
        let payer = TestPayer()
        let harness = try AgentHarness(approvePayment: payer.approve)
        defer { harness.close() }
        let url = try await harness.pages.serve("/mail", Self.shop("""
            <p>Your plan: $5.00 a month</p>
            <button id=send>Send</button>
            <button id=delete>Delete</button>
            <button id=remove type=submit form=billing>Delete card</button>
            <a id=methods href="#methods">Payment methods</a>
            <a id=history href="#history">Purchase history</a>
            <form id=billing onsubmit="return false"><input name=card-number autocomplete=cc-number></form>
            <button id=ru>Оплатить 500 ₽</button>
            <button id=uz>Sotib olish</button>
            <button id=de>Zahlungspflichtig bestellen</button>
            """))
        let agent = try await harness.agent(waits: HandoffTests.quick)
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text

        for name in [#"button "Send""#, #"button "Delete""#, #"button "Delete card""#, #"link "Payment methods""#,
                     #"link "Purchase history""#] {
            let ref = try #require(AgentClickTests.ref(of: name, in: outline), "\(name): \(outline)")
            let answer = try await agent.call("click", ["tab": "t1", "ref": .string(ref)])
            #expect(!answer.isError && answer.text.hasPrefix("clicked"), "\(name): \(answer.text)")
        }
        #expect(try await clicks(harness) == ["trusted send", "trusted delete", "trusted remove", "trusted methods", "trusted history"])
        #expect(payer.shown.isEmpty)

        for name in [#"button "Оплатить 500 ₽""#, #"button "Sotib olish""#, #"button "Zahlungspflichtig bestellen""#] {
            let ref = try #require(AgentClickTests.ref(of: name, in: outline), "\(name): \(outline)")
            let answer = try await agent.call("click", ["tab": "t1", "ref": .string(ref)])
            #expect(answer.text.contains("needs_user"), "\(name): \(answer.text)")
        }
        #expect(payer.shown.count == 3)
        #expect(payer.shown.first?.amounts == ["500 ₽"])
        #expect(try await clicks(harness).count == 5)
    }

    // MARK: Helpers

    /// A page that keeps every click in `window.clicks`, as
    /// "trusted pay" (a person's) or "script pay".
    static func shop(_ body: String) -> String {
        """
        <title>Shop</title>
        <script>window.clicks = []; document.addEventListener('click', (e) => {
            const target = e.target.closest('[id]');
            if (target) clicks.push((e.isTrusted ? 'trusted ' : 'script ') + target.id);
        });</script>
        \(body)
        """
    }

    private func ref(of element: String, _ agent: AgentTestClient) async throws -> String? {
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        return AgentClickTests.ref(of: element, in: outline)
    }

    private func page(_ harness: AgentHarness) throws -> WKWebView {
        try #require(harness.agents?.tabs.first?.page)
    }

    private func clicks(_ harness: AgentHarness) async throws -> [String] {
        try await page(harness).callAsyncJavaScript("return window.clicks", contentWorld: .page) as? [String] ?? []
    }
}

/// Stands in for the owner looking at payment sheets: keeps each card
/// shown and answers once `verdict` is set, a fresh verdict for each card.
@MainActor
final class TestPayer {
    private(set) var shown: [PaymentCard] = []
    var verdict: Bool?

    var approve: AgentPayments.Approve {
        { [self] card in
            shown.append(card)
            while verdict == nil {
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(50))
            }
            defer { verdict = nil }
            return verdict
        }
    }
}
