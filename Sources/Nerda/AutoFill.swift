import AppKit
import LocalAuthentication
import Security
import SwiftUI
import WebKit

// Contact info and cards, filled in as Safari and Chrome fill them: the
// passwords' script (Passwords.swift) also tells which boxes of a form take a
// name, an address or a card, lists those saved under the one the caret is
// in, and fills the form from the one picked. Card numbers are one item in
// the login keychain, as passwords are; a card's security code is never kept.

/// A name and address, with the email and phone that go with it.
nonisolated struct Contact: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var givenName = ""
    var familyName = ""
    var organisation = ""
    var line1 = ""
    /// The flat, suite or floor.
    var line2 = ""
    var city = ""
    /// A state, province or county.
    var region = ""
    var postalCode = ""
    var country = ""
    var email = ""
    var phone = ""

    var name: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }

    /// What a list shows of it: the name, or the street for one without.
    var title: String {
        [name, organisation, line1, email, phone].first { !$0.isEmpty } ?? ""
    }

    /// And under that, the street and town, or how to reach them.
    var summary: String {
        let place = [line1, city].filter { !$0.isEmpty && $0 != title }.joined(separator: ", ")
        return place.isEmpty ? [email, phone].first { !$0.isEmpty && $0 != title } ?? "" : place
    }

    /// What the boxes of a form take, by their autocomplete token.
    var values: [String: String] {
        let street = [line1, line2].filter { !$0.isEmpty }
        return [
            "name": name, "given-name": givenName, "family-name": familyName, "organization": organisation,
            "street-address": street.joined(separator: "\n"), "address-line1": line1, "address-line2": line2,
            "address-level2": city, "address-level1": region, "postal-code": postalCode, "country": country,
            "email": email, "tel": phone,
        ].filter { !$0.value.isEmpty }
    }

    /// Whether it is one kept already, at the same street and postcode.
    func isSame(as other: Contact) -> Bool {
        func key(_ address: Contact) -> [String] {
            [address.line1, address.postalCode].map { $0.lowercased().filter { !$0.isWhitespace } }
        }
        return key(self) == key(other)
    }
}

extension Contact {
    /// What a form sent, as an address worth keeping: one with a street and
    /// a town or postcode, as Chrome asks. A name sent whole is split at its
    /// last word.
    nonisolated init?(form: [String: String]) {
        func value(_ token: String) -> String { form[token]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var street = [value("address-line1"), value("address-line2"), value("address-line3")].filter { !$0.isEmpty }
        if street.isEmpty {
            street = value("street-address").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard let first = street.first, !value("address-level2").isEmpty || !value("postal-code").isEmpty else { return nil }
        line1 = first
        line2 = street.dropFirst().joined(separator: ", ")
        givenName = value("given-name")
        familyName = value("family-name")
        if givenName.isEmpty, familyName.isEmpty {
            var words = value("name").split(separator: " ").map(String.init)
            familyName = words.count > 1 ? words.removeLast() : ""
            givenName = words.joined(separator: " ")
        }
        organisation = value("organization")
        city = value("address-level2")
        region = value("address-level1")
        postalCode = value("postal-code")
        country = value("country")
        email = value("email")
        phone = value("tel")
    }
}

/// A payment card, without its number: only the last four digits, to tell
/// it by. The number is in the keychain (`CardNumbers`).
nonisolated struct Card: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// As printed on it.
    var name = ""
    var ending = ""
    var brand: String?
    var month = 0
    var year = 0
    var nickname = ""

    /// "Visa •••• 4242", or its nickname in place of Visa.
    var title: String {
        let what = nickname.isEmpty ? brand ?? "Card" : nickname
        return "\(what) \(CardNumber.masked(ending))"
    }

    var expiry: String { String(format: "%02d/%02d", month, year % 100) }

    /// What the boxes of a form take, by their autocomplete token.
    func values(number: String) -> [String: String] {
        ["cc-name": name, "cc-number": number, "cc-exp-month": String(format: "%02d", month), "cc-exp-year": String(year)]
            .filter { !$0.value.isEmpty }
    }

    /// The same card, kept already: the same last digits and expiry.
    func isSame(as other: Card) -> Bool {
        (ending, month, year) == (other.ending, other.month, other.year)
    }

    init(name: String = "", number: String = "", month: Int = 0, year: Int = 0, nickname: String = "") {
        self.name = name
        self.ending = String(number.suffix(4))
        self.brand = CardNumber.brand(of: number)
        self.month = month
        self.year = year
        self.nickname = nickname
    }

    /// What a form sent, as a card worth keeping, and its number: one whose
    /// number checks out and whose expiry reads.
    static func from(form: [String: String]) -> (card: Card, number: String)? {
        guard let number = form["cc-number"].flatMap(CardNumber.digits), CardNumber.isValid(number) else { return nil }
        let expiry = form["cc-exp"].flatMap(CardNumber.expiry)
            ?? form["cc-exp-month"].flatMap(CardNumber.month).flatMap { month in
                form["cc-exp-year"].flatMap(CardNumber.year).map { (month: month, year: $0) }
            }
        guard let expiry else { return nil }
        let name = form["cc-name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return (Card(name: name, number: number, month: expiry.month, year: expiry.year), number)
    }
}

/// Reading card numbers and expiry dates as people type them.
nonisolated enum CardNumber {
    /// The digits, without the spaces and dashes put between groups of
    /// them; nil for anything else.
    static func digits(_ typed: String) -> String? {
        let digits = typed.filter { $0 != " " && $0 != "-" }
        return !digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? digits : nil
    }

    /// 12 to 19 digits whose last one checks the rest (the Luhn check every
    /// card network uses), so a digit typed wrong is caught before it is kept.
    static func isValid(_ digits: String) -> Bool {
        guard (12...19).contains(digits.count) else { return false }
        var sum = 0
        for (place, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if place % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    /// The network, from the number's first digits.
    static func brand(of digits: String) -> String? {
        let two = Int(digits.prefix(2)) ?? 0, three = Int(digits.prefix(3)) ?? 0, four = Int(digits.prefix(4)) ?? 0
        return switch true {
        case digits.hasPrefix("4"): "Visa"
        case (51...55).contains(two), (2221...2720).contains(four): "Mastercard"
        case two == 34, two == 37: "American Express"
        case four == 6011, two == 65, (644...649).contains(three): "Discover"
        case (3528...3589).contains(four): "JCB"
        case two == 62: "UnionPay"
        case two == 36, two == 38, two == 39, (300...305).contains(three): "Diners Club"
        default: nil
        }
    }

    /// Its last four digits, after dots for the rest.
    static func masked(_ digits: String) -> String {
        "•••• \(digits.suffix(4))"
    }

    /// A month as a number (4, 04) or a name (April, Apr).
    static func month(_ typed: String) -> Int? {
        let typed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if let month = Int(typed) { return (1...12).contains(month) ? month : nil }
        guard typed.count >= 3 else { return nil }
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        return names.monthSymbols.firstIndex { $0.lowercased().hasPrefix(typed) }.map { $0 + 1 }
    }

    /// A year as 27 or 2027.
    static func year(_ typed: String) -> Int? {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard let year = Int(typed) else { return nil }
        switch typed.count {
        case 2: return 2000 + year
        case 4 where year >= 2000: return year
        default: return nil
        }
    }

    /// An expiry as cards print it, 04/27, or as forms take it: 04 / 2027, 0427.
    static func expiry(_ typed: String) -> (month: Int, year: Int)? {
        let groups = typed.split { !$0.isNumber }.map(String.init)
        let parts: (String, String)? = switch groups.count {
        case 2: (groups[0], groups[1])
        case 1 where [4, 6].contains(groups[0].count): (String(groups[0].prefix(2)), String(groups[0].dropFirst(2)))
        default: nil
        }
        guard let parts, let month = month(parts.0), let year = year(parts.1) else { return nil }
        return (month, year)
    }
}

/// The card numbers: one item in the login keychain, as the passwords are
/// (`Vault`), so a build the keychain doesn't know asks once, and only when
/// a number is wanted or kept.
actor CardNumbers {
    private let service: String
    /// By the card's id; nil until read, and while the keychain won't hand them over.
    private var numbers: [String: String]?
    /// Asked this run, and told no: not asked again until the next.
    private var refused = false

    init(service: String) {
        self.service = service
    }

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func load() -> [String: String]? {
        if let numbers { return numbers }
        if refused { return nil }
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &found) {
        case errSecSuccess:
            numbers = (found as? Data).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        case errSecItemNotFound:
            numbers = [:]
        default:
            refused = true
        }
        return numbers
    }

    func number(for card: UUID) -> String? {
        load()?[card.uuidString]
    }

    /// Keeps it, or with nil lets it go, touching no other card's: two saves
    /// at once each keep theirs. All or none, and a store that couldn't be
    /// read is never written over.
    func set(_ number: String?, for card: UUID) -> Bool {
        guard var all = load() else { return false }
        all[card.uuidString] = number
        guard let data = try? JSONEncoder().encode(all) else { return false }
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        numbers = all
        return true
    }
}

/// The addresses and cards kept, without the card numbers, in a file beside
/// the passwords' names: listing them under a box, or in Settings › AutoFill,
/// never touches the keychain.
@Observable
final class AutoFill {
    static let shared = AutoFill(file: Edition.folder.appending(path: "autofill.json"),
                                 numbers: CardNumbers(service: "\(Edition.name) Cards"))

    nonisolated struct Saved: Codable {
        var addresses: [Contact] = []
        var cards: [Card] = []
    }

    private(set) var addresses: [Contact] = []
    private(set) var cards: [Card] = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let numbers: CardNumbers

    init(file: URL, numbers: CardNumbers) {
        self.file = file
        self.numbers = numbers
        guard let data = try? Data(contentsOf: file) else { return }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            // Set aside rather than overwritten: it may be from a newer version.
            try? data.write(to: file.deletingLastPathComponent().appending(path: "autofill-unreadable.json"))
            return
        }
        addresses = saved.addresses
        cards = saved.cards
    }

    /// Whether addresses and cards are listed under a form's boxes, and
    /// offered to keep once sent (Settings › AutoFill).
    static let addressesKey = "fillsAddresses"
    static let cardsKey = "fillsCards"
    static var fillsAddresses: Bool { UserDefaults.standard.object(forKey: addressesKey) as? Bool ?? true }
    static var fillsCards: Bool { UserDefaults.standard.object(forKey: cardsKey) as? Bool ?? true }

    func save(_ address: Contact) {
        if let at = addresses.firstIndex(where: { $0.id == address.id }) { addresses[at] = address }
        else { addresses.append(address) }
        write()
    }

    func remove(_ address: Contact) {
        addresses.removeAll { $0.id == address.id }
        write()
    }

    /// With a new number for it, or nil to keep the one it has; all or none.
    func save(_ card: Card, number: String?) async -> Bool {
        if let number {
            guard await numbers.set(number, for: card.id) else { return false }
        }
        if let at = cards.firstIndex(where: { $0.id == card.id }) { cards[at] = card }
        else { cards.append(card) }
        write()
        return true
    }

    /// Gone from the list at once, and its number from the keychain if it
    /// hands it over; one it keeps is never read, as no card has its id.
    func remove(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        write()
        Task { _ = await numbers.set(nil, for: card.id) }
    }

    func number(for card: Card) async -> String? {
        guard cards.contains(where: { $0.id == card.id }) else { return nil }
        return await numbers.number(for: card.id)
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(addresses: addresses, cards: cards)).write(to: file, options: .atomic)
        } catch {
            NSLog("Nerda: couldn't save AutoFill: \(error)")
        }
    }

    /// Touch ID or the Mac's password, as Safari asks before it puts a card
    /// into a page. A Mac with neither has nothing to ask for.
    static func ownerConfirms(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// Which kind of thing a form's box takes, as the page's script tells it
    /// (`autofillToken`): its autocomplete token, or else the words in its
    /// name, id, label and placeholder, in English. null for any other box,
    /// a card's security code among them.
    static let classifier = #"""
        const autofillTokens = ['name', 'given-name', 'family-name', 'organization', 'street-address', 'address-line1',
            'address-line2', 'address-line3', 'address-level2', 'address-level1', 'postal-code', 'country', 'email', 'tel',
            'cc-name', 'cc-number', 'cc-exp', 'cc-exp-month', 'cc-exp-year'];
        // In order: the first that matches says what the box is.
        const autofillHints = [
            [/cvc|cvv|csc|security\s*code|card\s*code|verification|coupon|promo|discount|gift|captcha|nick/, null],
            [/user\s*name|login|password/, null],
            [/name\s*on\s*card|card\s*holder|holder\s*name|cc\s*name|card\s*name/, 'cc-name'],
            [/card\s*num|card\s*no\b|cc\s*num|credit\s*card|debit\s*card/, 'cc-number'],
            [/mm\s*[\/-]?\s*(yy|aa)/, 'cc-exp'],
            [/exp\w*\s*(month|mm\b)|cc\s*month|card\s*month/, 'cc-exp-month'],
            [/exp\w*\s*(year|yy)|cc\s*year|card\s*year/, 'cc-exp-year'],
            [/expir|exp\s*date|cc\s*exp/, 'cc-exp'],
            [/e.?mail/, 'email'],
            [/company|organi[sz]ation|business/, 'organization'],
            [/full\s*name|first\s*and\s*last|your\s*name/, 'name'],
            [/first\s*name|given\s*name|\bfname\b|forename/, 'given-name'],
            [/last\s*name|family\s*name|surname|\blname\b/, 'family-name'],
            [/address\s*(line)?\s*2|addr\s*2|apartment|\bapt\b|suite|\bunit\b|\bflat\b/, 'address-line2'],
            [/address\s*(line)?\s*3|addr\s*3/, 'address-line3'],
            [/zip|postal|post\s*code/, 'postal-code'],
            [/city|town|locality|suburb/, 'address-level2'],
            [/country/, 'country'],
            [/state|province|region|county/, 'address-level1'],
            [/phone|mobile|\btel\b/, 'tel'],
            [/street\s*name|road\s*name/, 'address-line1'],
            [/\bname\b/, 'name'],
            [/address|street|\baddr/, 'address-line1'],
        ];
        const autofillToken = (autocomplete, hints, type) => {
            const tokens = (autocomplete ?? '').toLowerCase().split(/\s+/).filter(Boolean);
            if (tokens.some((token) => ['username', 'current-password', 'new-password', 'one-time-code', 'webauthn'].includes(token))) return null;
            const named = tokens.at(-1) === 'country-name' ? 'country' : tokens.at(-1);
            if (autofillTokens.includes(named)) return named;
            // One the page named that isn't ours: a security code, a birthday.
            if (named?.startsWith('cc-') || named?.startsWith('bday')) return null;
            const words = (hints ?? '').replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().replace(/[_\-\[\]]/g, ' ');
            const hinted = autofillHints.find(([pattern]) => pattern.test(words));
            const token = hinted ? hinted[1] : type === 'email' ? 'email' : type === 'tel' ? 'tel' : null;
            return token === 'address-line1' && type === 'textarea' ? 'street-address' : token;
        };
        """#
}

/// What a form sent with an address or card in it that isn't kept, held
/// until the next page shows it went through.
struct SentForm {
    var address: Contact?
    var card: (card: Card, number: String)?
    let at = Date.now

    var isRecent: Bool { Date.now.timeIntervalSince(at) < 45 }
}

/// An address or card sent in a form, offered to keep.
struct AutoFillOffer: Equatable {
    enum Item: Equatable {
        case address(Contact)
        case card(Card, number: String)
    }

    let tab: Tab.ID
    let item: Item
}

extension Browser {
    /// What a page's form sent, from the passwords' script: kept until the
    /// next page loads, never in an incognito window.
    func page(_ page: WKWebView, sentForm body: [String: Any], on tab: Tab, clear: Bool, frame: WKFrameInfo?) {
        guard !isPrivate, Self.isPagesOwn(frame, on: tab) else { return }
        let autofill = AutoFill.shared
        var sent = SentForm()
        if AutoFill.fillsAddresses, let address = (body["address"] as? [String: String]).flatMap(Contact.init(form:)),
           !autofill.addresses.contains(where: { $0.isSame(as: address) }) {
            sent.address = address
        }
        if AutoFill.fillsCards, !clear, let card = (body["card"] as? [String: String]).flatMap(Card.from(form:)),
           !autofill.cards.contains(where: { $0.isSame(as: card.card) }) {
            sent.card = card
        }
        if sent.address != nil || sent.card != nil { tab.formSent = sent }
    }

    /// A new page is in: a form sent just before it went through, so what
    /// it held is offered to keep, the card first.
    func formLanded(on tab: Tab) {
        guard let sent = tab.formSent else { return }
        tab.formSent = nil
        guard sent.isRecent, tabs.contains(where: { $0 === tab }) else { return }
        var items: [AutoFillOffer.Item] = []
        if let card = sent.card { items.append(.card(card.card, number: card.number)) }
        if let address = sent.address { items.append(.address(address)) }
        withAnimation(.easeOut(duration: 0.14)) {
            autofillOffers += items.map { AutoFillOffer(tab: tab.id, item: $0) }
        }
    }

    func keepAutoFill(_ offer: AutoFillOffer) {
        dropAutoFill(offer)
        switch offer.item {
        case .address(let address):
            AutoFill.shared.save(address)
        case .card(let card, let number):
            Task {
                if await !AutoFill.shared.save(card, number: number) {
                    Self.tell("Couldn't save the card", "The keychain didn't take it.")
                }
            }
        }
    }

    func dropAutoFill(_ offer: AutoFillOffer) {
        guard let at = autofillOffers.firstIndex(of: offer) else { return }
        withAnimation(.easeOut(duration: 0.14)) { _ = autofillOffers.remove(at: at) }
    }

    /// One of the addresses listed, into the form it was listed under.
    func fill(_ address: Contact) {
        guard let (choices, page) = takeChoice() else { return }
        Task { await fillForm("address", address.values, choices: choices, on: page) }
    }

    /// One of the cards listed, once the person at the Mac says it is them.
    func fill(_ card: Card) {
        guard let (choices, page) = takeChoice() else { return }
        Task {
            guard await AutoFill.ownerConfirms("fill in your card details") else { return }
            guard let number = await AutoFill.shared.number(for: card) else {
                return Self.tell("Couldn't fill in the card", "The keychain didn't hand over its number.")
            }
            await fillForm("card", card.values(number: number), choices: choices, on: page)
        }
    }

    private func fillForm(_ kind: String, _ values: [String: String], choices: PasswordChoices, on page: WKWebView) async {
        _ = try? await page.callAsyncJavaScript(
            "return nerdaFillForm(kind, values, site, secure)",
            arguments: ["kind": kind, "values": values, "site": choices.site, "secure": !choices.clear],
            in: choices.frame,
            contentWorld: Passwords.world
        )
        page.window?.makeFirstResponder(page)
    }

    /// The page's own frame: the top one, or one from the same origin as the
    /// document in it (`committed`, not the address of one still on its way).
    /// A frame from another site (an ad, a payment provider's) is filled by
    /// nothing of the page's.
    static func isPagesOwn(_ frame: WKFrameInfo?, on tab: Tab) -> Bool {
        guard let frame, !frame.isMainFrame else { return true }
        let origin = frame.securityOrigin
        return tab.committed?.scheme == origin.protocol && tab.committed?.host() == origin.host
            && (tab.committed?.port ?? 0) == origin.port
    }
}

/// After a form went through: keep the address or card it held?
struct AutoFillOfferBar: View {
    let browser: Browser
    let offer: AutoFillOffer

    var body: some View {
        switch offer.item {
        case .address(let address):
            OfferBar(icon: "person.text.rectangle", title: "Save this address?",
                     detail: [address.title, address.summary].filter { !$0.isEmpty }.joined(separator: ", ")) { buttons }
        case .card(let card, _):
            OfferBar(icon: "creditcard", title: "Save this card?", detail: "\(card.title), expires \(card.expiry)") { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Not Now") { browser.dropAutoFill(offer) }
        Button("Save") { browser.keepAutoFill(offer) }
            .buttonStyle(.borderedProminent)
    }
}
