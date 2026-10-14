import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Nerda

/// A box is known by the autocomplete token the page gave it, or else by
/// the words in its name, id and label; a card's security code, a sign-in's
/// name and a token the page made up for itself are none of AutoFill's.
@MainActor @Test func formBoxesAreKnownByTokenOrName() {
    let context = JSContext()!
    context.evaluateScript(AutoFill.classifier)
    #expect(context.exception == nil)
    func token(_ autocomplete: String, _ hints: String, _ type: String = "text") -> String? {
        let value = context.evaluateScript("autofillToken")!.call(withArguments: [autocomplete, hints, type])!
        return value.isNull ? nil : value.toString()
    }
    #expect(token("shipping address-line1", "") == "address-line1")
    #expect(token("section-billing billing country-name", "") == "country")
    #expect(token("cc-csc", "card number") == nil)
    #expect(token("username", "email", "email") == nil)
    #expect(token("off", "checkout[shipping_address][first_name]") == "given-name")
    #expect(token("nope", "billingLastName") == "family-name")
    #expect(token("", "Full name") == "name")
    #expect(token("", "Company (optional)") == "organization")
    #expect(token("", "checkout[shipping_address][address1]") == "address-line1")
    #expect(token("", "Apartment, suite, etc. (optional)") == "address-line2")
    #expect(token("", "Address", "textarea") == "street-address")
    #expect(token("", "Town/City") == "address-level2")
    #expect(token("", "Country/region", "select-one") == "country")
    #expect(token("", "State") == "address-level1")
    #expect(token("", "ZIP code") == "postal-code")
    #expect(token("", "Phone", "tel") == "tel")
    #expect(token("", "contact", "email") == "email")
    #expect(token("", "Name on card") == "cc-name")
    #expect(token("", "cardNumber 1234 1234 1234 1234") == "cc-number")
    #expect(token("", "Expiry date MM / YY") == "cc-exp")
    #expect(token("", "exp_month", "select-one") == "cc-exp-month")
    #expect(token("", "expirationYear", "select-one") == "cc-exp-year")
    #expect(token("", "Security code") == nil)
    #expect(token("", "Gift card number") == nil)
    #expect(token("", "Search") == nil)
}

/// A number is a card's only when its check digit agrees (Luhn); spaces and
/// dashes between groups are taken out, and a card is shown only by its
/// last four digits.
@Test func cardNumbersAreCheckedAndMasked() {
    #expect(CardNumber.digits("4242 4242-4242 4242") == "4242424242424242")
    #expect(CardNumber.digits("4242 42x2") == nil)
    #expect(CardNumber.isValid("4242424242424242"))
    #expect(CardNumber.isValid("378282246310005"))
    #expect(!CardNumber.isValid("4242424242424241"))
    #expect(!CardNumber.isValid("42424"))
    #expect(CardNumber.brand(of: "4242424242424242") == "Visa")
    #expect(CardNumber.brand(of: "5555555555554444") == "Mastercard")
    #expect(CardNumber.brand(of: "2223003122003222") == "Mastercard")
    #expect(CardNumber.brand(of: "378282246310005") == "American Express")
    #expect(CardNumber.masked("4242424242424242") == "•••• 4242")
    let card = Card(name: "Jane Doe", number: "4242424242424242", month: 4, year: 2027)
    #expect(card.title == "Visa •••• 4242")
    #expect(card.expiry == "04/27")
    var named = card
    named.nickname = "Work"
    #expect(named.title == "Work •••• 4242")
}

/// Expiry dates as cards print them and forms take them, and what a form
/// sent as a card: kept only with a number that checks out and an expiry.
@Test func cardsAreReadFromWhatAFormSent() {
    #expect(CardNumber.expiry("04/27").map { [$0.month, $0.year] } == [4, 2027])
    #expect(CardNumber.expiry("4 / 2027").map { [$0.month, $0.year] } == [4, 2027])
    #expect(CardNumber.expiry("0427").map { [$0.month, $0.year] } == [4, 2027])
    #expect(CardNumber.expiry("13/27") == nil)
    #expect(CardNumber.month("April") == 4)
    #expect(CardNumber.month("Sep") == 9)

    let sent = Card.from(form: ["cc-number": "4242 4242 4242 4242", "cc-exp-month": "April", "cc-exp-year": "2027", "cc-name": " Jane Doe "])
    #expect(sent?.number == "4242424242424242")
    #expect(sent.map { [$0.card.ending, $0.card.name, $0.card.expiry] } == ["4242", "Jane Doe", "04/27"])
    #expect(Card.from(form: ["cc-number": "4242424242424241", "cc-exp": "04/27"]) == nil)
    #expect(Card.from(form: ["cc-number": "4242424242424242"]) == nil)
}

/// An address sent in a form is worth keeping with a street and a town or
/// postcode; a name sent whole is split at its last word.
@Test func addressesAreReadFromWhatAFormSent() {
    let sent = Contact(form: ["name": "Mary Ann Smith", "address-line1": "1 High Street", "address-line2": "Flat 2",
                              "address-level2": "London", "postal-code": "SW1A 1AA", "email": "mary@example.com"])
    #expect(sent?.givenName == "Mary Ann")
    #expect(sent?.familyName == "Smith")
    #expect(sent?.values["street-address"] == "1 High Street\nFlat 2")
    #expect(sent?.title == "Mary Ann Smith")
    #expect(sent?.summary == "1 High Street, London")
    #expect(Contact(form: ["street-address": "5 Main St\nApt 3", "postal-code": "10001"])?.line2 == "Apt 3")
    #expect(Contact(form: ["name": "Jane", "email": "jane@example.com"]) == nil)
    var other = Contact()
    other.line1 = "1 high street"
    other.postalCode = "sw1a1aa"
    #expect(sent.map(other.isSame) == true)
}

/// Addresses and cards come back as they were saved, the cards without
/// their numbers: those are only in the keychain, which this leaves alone.
@MainActor @Test func savedAddressesAndCardsComeBack() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let numbers = CardNumbers(service: "Nerda Tests \(UUID().uuidString)")
    let autofill = AutoFill(file: file, numbers: numbers)
    var contact = Contact()
    contact.givenName = "Jane"
    contact.line1 = "1 Main St"
    autofill.save(contact)
    let card = Card(name: "Jane", number: "4242424242424242", month: 4, year: 2027)
    #expect(await autofill.save(card, number: nil))

    let again = AutoFill(file: file, numbers: numbers)
    #expect(again.addresses == [contact])
    #expect(again.cards == [card])
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("4242424242424242"))
    again.remove(contact)
    #expect(AutoFill(file: file, numbers: numbers).addresses.isEmpty)
}

/// Two cards saved at once keep both their numbers, and removing one lets
/// only its own number go. Uses a keychain item of its own, deleted after.
@MainActor @Test func cardsSavedTogetherKeepTheirNumbers() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    let service = "Nerda Tests \(UUID().uuidString)"
    defer {
        try? FileManager.default.removeItem(at: file)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
    let autofill = AutoFill(file: file, numbers: CardNumbers(service: service))
    let first = Card(name: "Jane", number: "4242424242424242", month: 4, year: 2027)
    let second = Card(name: "Jane", number: "5555555555554444", month: 5, year: 2028)
    async let savedFirst = autofill.save(first, number: "4242424242424242")
    async let savedSecond = autofill.save(second, number: "5555555555554444")
    #expect(await [savedFirst, savedSecond] == [true, true])

    let again = AutoFill(file: file, numbers: CardNumbers(service: service))
    #expect(await again.number(for: first) == "4242424242424242")
    #expect(await again.number(for: second) == "5555555555554444")
    let numbers = CardNumbers(service: service)
    #expect(await numbers.set(nil, for: first.id))
    #expect(await numbers.number(for: first.id) == nil)
    #expect(await numbers.number(for: second.id) == "5555555555554444")
}

/// A frame's form is the page's own by the document the tab shows, not by
/// the address of one on its way: that is the page's `url` already.
@MainActor @Test func aFramesFormIsJudgedByTheDocumentShown() async throws {
    let browser = Browser(dataStore: .nonPersistent())
    let tab = Tab()
    browser.add(tab)
    let shown = URL(string: "https://shop.example/checkout")!
    tab.webView.loadHTMLString("<p>Pay</p>", baseURL: shown)
    for _ in 0..<250 where tab.committed != shown { try await Task.sleep(for: .milliseconds(20)) }
    tab.webView.load(URLRequest(url: URL(string: "https://elsewhere.invalid/")!))
    #expect(tab.webView.url?.host() == "elsewhere.invalid")
    #expect(tab.committed == shown)
}

/// An address picked under a box fills that box's run of the form, lists
/// included, and leaves the billing address after it alone.
@MainActor @Test func aPickedAddressFillsItsPartOfTheForm() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    Passwords.install(in: configuration.userContentController)
    let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    page.loadHTMLString("""
        <form>
          <input id=first name=first_name><input id=last name=last_name>
          <input id=street name=address1><input id=city name=city>
          <select id=country name=country><option value="">Choose</option><option value=GB>United Kingdom</option></select>
          <input id=billing-street name=billing_address1><input id=billing-city name=billing_city>
        </form>
        """, baseURL: URL(string: "https://shop.test/")!)
    for _ in 0..<300 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(100))
    _ = try await page.callAsyncJavaScript("document.getElementById('first').focus()", contentWorld: .page)

    var contact = Contact()
    contact.givenName = "Jane"
    contact.familyName = "Doe"
    contact.line1 = "1 High Street"
    contact.city = "London"
    contact.country = "United Kingdom"
    let fill = "return nerdaFillForm('address', values, site, true)"
    #expect(try await page.callAsyncJavaScript(fill, arguments: ["values": contact.values, "site": "elsewhere.test"],
                                               contentWorld: Passwords.world) as? Bool == false)
    #expect(try await page.callAsyncJavaScript(fill, arguments: ["values": contact.values, "site": "shop.test"],
                                               contentWorld: Passwords.world) as? Bool == true)
    let read = "return ['first', 'last', 'street', 'city', 'country', 'billing-street'].map((id) => document.getElementById(id).value)"
    #expect(try await page.callAsyncJavaScript(read, contentWorld: .page) as? [String]
        == ["Jane", "Doe", "1 High Street", "London", "GB", ""])
}

/// A page with no form gets only the passwords' starter: it still answers
/// whether the page asks for a password, and a form the page adds later
/// and sends at once, its boxes never gone to, still has its sign-in heard.
@MainActor @Test func theRestOfThePasswordsScriptComesWhenAFormIsUsed() async throws {
    let browser = Browser(dataStore: .nonPersistent())
    let tab = Nerda.Tab()
    browser.add(tab)
    let page = tab.webView
    page.loadHTMLString("<p>Nothing to sign in to</p>", baseURL: URL(string: "https://shop.test/")!)
    for _ in 0..<300 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(100))
    func run(_ script: String) async throws -> Any? {
        try await page.callAsyncJavaScript(script, contentWorld: Passwords.world)
    }
    #expect(try await run("return typeof nerdaFill") as? String == "undefined")
    #expect(try await run("return nerdaAsksForPassword()") as? Bool == false)

    _ = try await page.callAsyncJavaScript("""
        document.body.insertAdjacentHTML('beforeend', `<form onsubmit="event.preventDefault()">
            <input name=username value=jane><input type=password value=secret></form>`);
        """, contentWorld: .page)
    #expect(try await run("return nerdaAsksForPassword()") as? Bool == true)
    #expect(try await run("return typeof nerdaFill") as? String == "undefined")
    _ = try await page.callAsyncJavaScript("document.forms[0].requestSubmit()", contentWorld: .page)
    for _ in 0..<100 where tab.signIn == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(tab.signIn?.user == "jane" && tab.signIn?.password == "secret" && tab.signIn?.host == "shop.test")
    #expect(try await run("return typeof nerdaFill") as? String == "function")

    // A box outside any form, gone to.
    page.loadHTMLString("<input id=box>", baseURL: URL(string: "https://shop.test/again")!)
    for _ in 0..<300 where page.isLoading || page.url?.path() != "/again" { try await Task.sleep(for: .milliseconds(20)) }
    #expect(try await run("return typeof nerdaFill") as? String == "undefined")
    _ = try await page.callAsyncJavaScript("document.getElementById('box').focus()", contentWorld: .page)
    for _ in 0..<100 where try await run("return typeof nerdaFill") as? String != "function" { try await Task.sleep(for: .milliseconds(20)) }
    #expect(try await run("return typeof nerdaFill") as? String == "function")
}
