import AppKit
import CryptoKit

/// A press an agent makes that would pay, as the page weighs it
/// (`AgentPayments.weigher`): a pay button, or sending a form that holds
/// card fields.
struct AgentPayment {
    enum Reason: String {
        /// What it says: Pay, Buy now, Place order, Оплатить, To'lash…
        case words
        /// It sends card fields: a card's number, code or expiry.
        case card
    }

    let tab: AgentTab
    /// The element pressed: its ref, or without one its role and name.
    let element: String
    /// How the agent and the owner are told of it: e12 button "Pay now".
    let what: String
    /// The amounts the page shows for it, as written: $12.00.
    let amounts: [String]
    let reason: Reason

    /// A digest of the amounts: an approval fits only these.
    var digest: String {
        let joined = amounts.map { $0.lowercased() }.sorted().joined(separator: "|")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether it is a press of the same element of the same tab.
    func isOnSameElement(as other: AgentPayment) -> Bool {
        tab.tab === other.tab.tab && element == other.element
    }
}

/// What the owner is shown on a payment's sheet.
struct PaymentCard {
    /// The agent paying, as the owner knows it: Claude, Codex.
    let asker: String
    /// The site it pays on.
    let site: String
    /// What it pressed: e12 button "Pay now".
    let what: String
    let amounts: [String]
    /// Its Agent tab: t1.
    let tab: String
}

/// Payments agents press, each held until the owner approves it with Touch
/// ID on a sheet over their window, which doesn't bring Nerda forward. The
/// owner hears of it as of a Handoff (a notification, the Agent row). An
/// approval fits the element pressed and the amounts the page showed, for
/// `approvalLasts`, and is used by one press; declined, the agent is told.
/// Sending and deleting are never held: only what weighs as a payment.
@MainActor
final class AgentPayments {
    /// Shows the owner a payment: true once they approved it (Touch ID or
    /// their Mac's password), false when they didn't, nil when they made no
    /// choice (the window closed under the sheet, or the hold went first).
    typealias Approve = @MainActor (PaymentCard) async -> Bool?

    /// How long an approval waits for its press.
    static let approvalLasts: Duration = .seconds(120)

    /// A payment held for the owner, answered or not.
    final class Hold {
        enum State {
            case waiting
            case approved(ContinuousClock.Instant)
            case declined(ContinuousClock.Instant)
        }

        let payment: AgentPayment
        let digest: String
        let request: OwnerRequest
        fileprivate(set) var state = State.waiting
        fileprivate var asking: Task<Void, Never>?

        fileprivate init(payment: AgentPayment, request: OwnerRequest) {
            self.payment = payment
            digest = payment.digest
            self.request = request
        }

        /// The same element, tab and amounts.
        func fits(_ other: AgentPayment) -> Bool {
            payment.isOnSameElement(as: other) && digest == other.digest
        }

        var isWaiting: Bool { if case .waiting = state { true } else { false } }
    }

    private let owner: OwnerRequests
    private let approve: Approve
    private(set) var holds: [Hold] = []

    init(owner: OwnerRequests, approve: @escaping Approve) {
        self.owner = owner
        self.approve = approve
    }

    /// Returns once the press may go: it pays nothing, or the owner
    /// approved this payment (and the approval is used up). Otherwise holds
    /// it, telling the owner, and waits as long as the call may; fails with
    /// needs_user when the owner hasn't answered by then, or with what they
    /// said. `again` is how the agent repeats the press: click on e12.
    func clear(_ press: AgentPage.Press, on tab: AgentTab, for call: AgentCall, again: String) async throws {
        while true {
            guard let payment = try await AgentPage.payment(press, in: tab) else { return }
            expire()
            if let approved = holds.first(where: { $0.fits(payment) && !$0.isWaiting }) {
                remove(approved)
                guard case .approved = approved.state else {
                    throw AgentError(.failed, """
                        The user didn't approve the payment (\(payment.what)\(Self.amounts(payment))), so Nerda didn't \
                        press it. Don't try it another way; ask the user what to do.
                        """)
                }
                // What else was asked on this element is answered by this press.
                for other in holds where other.payment.isOnSameElement(as: payment) && other.isWaiting { end(other) }
                return
            }
            let hold = holds.first { $0.fits(payment) && $0.isWaiting } ?? begin(payment, for: call.session)
            // Asked for another amount before: that sheet is out of date.
            for other in holds where other !== hold && other.payment.isOnSameElement(as: payment) && other.isWaiting {
                end(other)
            }
            // Room left after it for the press and the page to settle.
            let until = ContinuousClock.now + AgentVerb.waitOnOwner(call, leaving: .seconds(5))
            while hold.isWaiting, hold.request.answer == nil, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(100))
            }
            if hold.isWaiting {
                if hold.request.answer != nil {
                    end(hold)
                    throw AgentError(.noTab, "Tab \(tab.ref) was closed while the payment waited for the user.")
                }
                throw AgentError.needsUser("""
                    \(payment.what) pays\(Self.amounts(payment)), so Nerda holds it until the user approves it \
                    with Touch ID in Nerda's window, and nothing is pressed meanwhile.
                    """, waitingIn: "in Nerda's window", again: again)
            }
            // Answered: weighed again, so an approval goes to these amounts only.
        }
    }

    /// The amounts as the agent is told them: " $12.00", or nothing.
    private static func amounts(_ payment: AgentPayment) -> String {
        payment.amounts.isEmpty ? "" : " " + payment.amounts.prefix(3).joined(separator: ", ")
    }

    /// A payment held: the owner told (notification, Agent row) and shown
    /// its sheet; the hold let go of if its request ends first (the tab
    /// closed, the agent stopped).
    private func begin(_ payment: AgentPayment, for session: AgentSession) -> Hold {
        let tab = payment.tab
        let site = tab.tab.url.flatMap(History.site(of:)) ?? "a page"
        let amounts = payment.amounts.isEmpty ? "" : " " + payment.amounts.prefix(3).joined(separator: ", ")
        let request = owner.payment("""
            Pay\(amounts) on \(site): \(payment.what) in \(tab.ref). Approve it with Touch ID on the sheet in \
            Nerda's window, or don't.
            """, on: tab, for: session)
        let hold = Hold(payment: payment, request: request)
        holds.append(hold)
        let card = PaymentCard(asker: session.title, site: site, what: payment.what, amounts: payment.amounts, tab: tab.ref)
        hold.asking = Task { [weak self, approve] in
            let approved = await approve(card)
            guard let self, hold.isWaiting, !Task.isCancelled else { return }
            hold.state = approved == true ? .approved(.now) : .declined(.now)
            owner.drop(request)
        }
        Task { [weak self] in
            while hold.isWaiting {
                if hold.request.answer != nil {
                    self?.end(hold)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return hold
    }

    /// Lets go of a hold: its sheet taken away, its request withdrawn.
    private func end(_ hold: Hold) {
        hold.asking?.cancel()
        owner.drop(hold.request)
        remove(hold)
    }

    private func remove(_ hold: Hold) {
        holds.removeAll { $0 === hold }
    }

    /// Approvals past their time, and refusals nobody asked about again
    /// in ten minutes.
    private func expire() {
        let now = ContinuousClock.now
        for hold in holds {
            switch hold.state {
            case .approved(let at) where now - at > Self.approvalLasts: remove(hold)
            case .declined(let at) where now - at > .seconds(600): remove(hold)
            default: break
            }
        }
    }

    // MARK: The sheet

    /// Shows the payment on a sheet over the owner's window, which doesn't
    /// bring Nerda forward (with no window open, once they open one); its
    /// Pay button asks for Touch ID or the Mac's password. Taken away when
    /// the hold goes first.
    static func sheet(_ card: PaymentCard) async -> Bool? {
        guard let window = await AgentApprovals.ownersWindow(), !Task.isCancelled else { return nil }
        let alert = NSAlert()
        alert.messageText = "\(card.asker) wants to pay on \(card.site)"
        let amounts = card.amounts.isEmpty
            ? "Nerda found no amount on the page."
            : "The page shows \(card.amounts.prefix(3).joined(separator: ", "))."
        alert.informativeText = """
            It pressed \(card.what) in its tab \(card.tab). \(amounts) Pay only if you asked it to buy this: \
            Touch ID or your password approves this one press.
            """
        alert.addButton(withTitle: "Pay with Touch ID")
        alert.addButton(withTitle: "Don't Pay")
        // Return pressed while typing in the window mustn't approve it.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let response = await withTaskCancellationHandler {
            await alert.beginSheetModal(for: window)
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .cancel) }
        }
        switch response {
        case .alertFirstButtonReturn:
            guard !Task.isCancelled else { return nil }
            return await AutoFill.ownerConfirms("approve \(card.asker)'s payment on \(card.site)")
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    // MARK: Weighing a press in the page

    /// The script that weighs a press: `(win, g) => weigh`, where `g` holds
    /// helpers captured before any agent code ran (`AgentEvalGuard`'s
    /// `guard`, or `helpers` in the page model's world) and `weigh(element,
    /// how, key)` answers `{why, name, amounts, element}` for a press that
    /// pays, or null. `how` is `click` (a click, or Enter or Space on a
    /// button), `key` (the key `key` in a field, a frame of another site
    /// holding the keyboard) or `submit` (a form sent as it is).
    ///
    /// A payment is a press of something that says it pays (`pay`, in
    /// English, Russian, Uzbek, German, French and Spanish), or that says
    /// it subscribes, confirms, orders… with an amount in its name; or one
    /// sending a form that holds card fields (by autocomplete, name or
    /// label, a value that is a card's number, or a payment provider's
    /// frame), or a button beside such fields with no form. Cancel, back,
    /// delete, send and the like never are. Written as the eval guard's
    /// parts are: only what `g` and `win` give, index loops, no array or
    /// string methods.
    nonisolated static let weigher = #"""
        (win, g) => {
            const { apply, describe, lower, matches, pattern, tag, attribute } = g;
            const getter = (owner, name) => { const property = owner && describe(owner, name); return property ? property.get : null; };
            const read = (get, node) => { try { return get ? apply(get, node, []) : null; } catch { return null; } };
            const nodeTypeOf = getter(win.Node.prototype, 'nodeType');
            const parentOf = getter(win.Node.prototype, 'parentNode');
            const hostOf = getter(win.ShadowRoot.prototype, 'host');
            const textOf = getter(win.Node.prototype, 'textContent');
            const shownTextOf = getter(win.HTMLElement.prototype, 'innerText');
            const valueOf = getter(win.HTMLInputElement.prototype, 'value');
            const forms = { __proto__: null, button: getter(win.HTMLButtonElement.prototype, 'form'), input: getter(win.HTMLInputElement.prototype, 'form'),
                select: getter(win.HTMLSelectElement.prototype, 'form'), textarea: getter(win.HTMLTextAreaElement.prototype, 'form') };
            const controlOf = getter(win.HTMLLabelElement.prototype, 'control');
            const elementsOf = getter(win.HTMLFormElement.prototype, 'elements');
            const collectionLength = getter(win.HTMLCollection.prototype, 'length');
            const collectionItem = win.HTMLCollection.prototype.item;
            const selectAll = win.Element.prototype.querySelectorAll;
            const listLength = getter(win.NodeList.prototype, 'length');
            const listItem = win.NodeList.prototype.item;

            const pay = pattern(/(?<![\p{L}\p{N}])(?:pay|buy|purchase|donate|place\s+(?:your\s+|my\s+|the\s+)?order|(?:complete|confirm|submit|finish)\s+(?:and\s+pay|(?:your\s+|my\s+|the\s+)?(?:order|purchase|payment|booking))|order\s+now|(?:book|reserve|subscribe|order)\s+and\s+pay|оплатить|заплатить|купить|оформить\s+заказ|сделать\s+заказ|(?:подтвердить|завершить)\s+(?:заказ|оплату|покупку|платёж|платеж)|to[ʻ'‘’`]?la(?:sh|ng|moq)|to[ʻ'‘’`]?lovni\s+(?:tasdiqla(?:sh|ng)|amalga\s+oshir(?:ish|ing))|sotib\s+ol(?:ish|ing)|xarid\s+qil(?:ish|ing)|buyurtma\s+ber(?:ish|ing)|buyurtmani\s+(?:tasdiqla(?:sh|ng)|rasmiylashtir(?:ish|ing))|тўла(?:ш|нг|моқ)|тўловни\s+тасдиқла(?:ш|нг)|сотиб\s+ол(?:иш|инг)|харид\s+қил(?:иш|инг)|буюртма\s+бер(?:иш|инг)|буюртмани\s+(?:тасдиқла(?:ш|нг)|расмийлаштир(?:иш|инг))|(?:jetzt\s+)?(?:be)?zahlen|(?:zahlungs|kosten)pflichtig\s+bestellen|(?:jetzt\s+)?kaufen|(?:bestellung|kauf)\s+(?:abschließen|abschicken|bestätigen)|payer|acheter|(?:passer|valider|confirmer|finaliser)\s+(?:la\s+|ma\s+|votre\s+)?commande|confirmer\s+(?:le\s+|mon\s+)?(?:paiement|achat)|pagar|comprar|(?:realizar|confirmar|finalizar|completar)\s+(?:el\s+|mi\s+|tu\s+|la\s+)?(?:pedido|compra|pago))(?![\p{L}\p{N}])(?!\s+(?:it\s+)?(?:history|histories|methods?|options?|settings|details|summary|info|information|terms|policy|protection|plans?|again))/iu);
            const commits = pattern(/(?<![\p{L}\p{N}])(?:subscribe|upgrade|confirm|continue|complete|start|order|renew|check\s*out|reserve|book|join|submit|подписаться|продлить|подтвердить|obuna)(?![\p{L}\p{N}])/iu);
            const never = pattern(/^(?:cancel|back|go\s+back|close|remove|delete|edit|change|send|отмена|отменить|назад|удалить|отправить|bekor\s+qilish|orqaga|o[ʻ'‘’`]?chirish|yuborish)(?![\p{L}\p{N}])/iu);
            const cardComplete = pattern(/(?:^|\s)cc-(?:number|csc|exp|exp-month|exp-year)(?:\s|$)/);
            const cardWords = pattern(/card.?(?:number|num\b|no\b)|cc.?(?:num|number)|credit.?card|\bcvc|cvv|cvn|\bcsc\b|security.?code|card.?code|card.?exp|exp(?:iry|iration).?date|номер\s*карты|karta\s*raqami|карта\s*рақами|kartennummer|numéro\s*de\s*carte|número\s*de\s*tarjeta/i);
            const cardFrames = pattern(/stripe|braintree|adyen|checkout\.com|squareup|paypal|recurly|chargebee|cybersource|worldpay|mollie|klarna|card|payment|cvc|cvv/i);
            const pressRoles = pattern(/^(?:button|link|menuitem|menuitemradio|option|tab)$/);
            const money = pattern(/(?:[$€£¥₽₹₩₺₴₸₦₱฿₫₪]|(?<!\p{L})(?:us\$|a\$|c\$|usd|eur|gbp|rub|uzs|chf|cad|aud|jpy|cny|kzt|uah)(?!\p{L}))\s?(?:\d{1,3}(?:[ ,.\u00a0\u202f']\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)|(?:\d{1,3}(?:[ ,.\u00a0\u202f']\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s?(?:[$€£¥₽₹₩₺₴₸₦₱฿₫₪]|(?:usd|eur|gbp|rub|uzs|chf|cad|aud|jpy|cny|kzt|uah|руб|р\.|сум|сўм|so[ʻ'‘’`]?m|zł|kr|kč|lei)(?!\p{L}))/giu);

            const blank = { __proto__: null, ' ': 1, '\n': 1, '\t': 1, '\r': 1, '\f': 1, '\u00a0': 1, '\u202f': 1 };
            /// Text with its runs of space made one, trimmed, at most `most` long.
            const tidy = (value, most) => {
                const all = value === null || value === undefined ? '' : '' + value;
                let out = '', space = false;
                for (let i = 0; i < all.length && out.length < most; i++) {
                    const c = all[i];
                    if (blank[c] === 1) { space = out.length > 0; continue; }
                    if (space) { out += ' '; space = false; }
                    out += c;
                }
                return out;
            };
            const shownText = (node, most) => tidy(read(shownTextOf, node) ?? read(textOf, node), most);
            const up = (node) => {
                const parent = read(parentOf, node);
                if (!parent) return null;
                return read(nodeTypeOf, parent) === 11 ? read(hostOf, parent) : parent;
            };
            const each = (root, selector, visit) => {
                let list;
                try { list = apply(selectAll, root, [selector]); } catch { return false; }
                const count = read(listLength, list) ?? 0;
                for (let i = 0; i < count; i++) if (visit(apply(listItem, list, [i]))) return true;
                return false;
            };
            const formOf = (node) => {
                const get = forms[tag(node)];
                if (get) return read(get, node);
                for (let at = up(node), depth = 0; at && depth < 40; at = up(at), depth++) if (tag(at) === 'form') return at;
                return null;
            };
            /// A number that is a card's: 13 to 19 digits passing Luhn's check.
            const isCardNumber = (value) => {
                const all = value === null || value === undefined ? '' : '' + value;
                let digits = '';
                for (let i = 0; i < all.length; i++) {
                    const c = all[i];
                    if (c >= '0' && c <= '9') digits += c;
                    else if (c !== ' ' && c !== '-') return false;
                }
                if (digits.length < 13 || digits.length > 19) return false;
                let sum = 0;
                for (let i = 0; i < digits.length; i++) {
                    let digit = +digits[digits.length - 1 - i];
                    if (i % 2 === 1) { digit *= 2; if (digit > 9) digit -= 9; }
                    sum += digit;
                }
                return sum % 10 === 0;
            };
            const cardField = (element) => {
                const kind = tag(element);
                const words = attribute(element, 'name') + ' ' + attribute(element, 'id') + ' ' + attribute(element, 'aria-label') + ' ' +
                    attribute(element, 'placeholder') + ' ' + attribute(element, 'title') + ' ' + attribute(element, 'data-testid');
                if (kind === 'iframe' || kind === 'frame') return matches(cardFrames, attribute(element, 'src') + ' ' + words);
                if (kind !== 'input' && kind !== 'select') return false;
                const type = lower(attribute(element, 'type') ?? '');
                if (type === 'hidden' || type === 'submit' || type === 'button' || type === 'image' || type === 'checkbox' || type === 'radio') return false;
                if (matches(cardComplete, lower(attribute(element, 'autocomplete') ?? ''))) return true;
                if (matches(cardWords, words)) return true;
                return kind === 'input' && isCardNumber(read(valueOf, element));
            };
            const holdsCard = (root) => {
                if (!root) return false;
                if (tag(root) === 'form') {
                    const elements = read(elementsOf, root);
                    const count = read(collectionLength, elements) ?? 0;
                    for (let i = 0; i < count; i++) if (cardField(apply(collectionItem, elements, [i]))) return true;
                }
                return each(root, 'input, select, iframe, frame', cardField);
            };
            /// Card fields close round a button with no form: a few levels up.
            const nearCard = (node) => {
                for (let at = up(node), depth = 0; at && depth < 3; at = up(at), depth++) {
                    const kind = tag(at);
                    if (kind === 'body' || kind === 'html') return false;
                    if (holdsCard(at)) return true;
                }
                return false;
            };
            /// What is pressed: the button, link or field round `element`.
            const control = (element) => {
                let node = element;
                for (let depth = 0; node && depth < 12; depth++) {
                    const kind = tag(node);
                    if (kind === 'label') {
                        const target = read(controlOf, node);
                        if (target && tag(target) !== 'label') return control(target);
                    }
                    if (kind === 'button') {
                        const type = lower(attribute(node, 'type') ?? '');
                        return { node, kind: type === 'button' ? 'button' : type === 'reset' ? 'other' : 'submit' };
                    }
                    if (kind === 'input') {
                        const type = lower(attribute(node, 'type') ?? '');
                        if (type === 'submit' || type === 'image') return { node, kind: 'submit' };
                        if (type === 'button') return { node, kind: 'button' };
                        const other = { __proto__: null, reset: 1, checkbox: 1, radio: 1, hidden: 1, file: 1, range: 1, color: 1 };
                        return { node, kind: other[type] === 1 ? 'other' : 'field' };
                    }
                    if (kind === 'select' || kind === 'textarea') return { node, kind: 'other' };
                    if (kind === 'iframe' || kind === 'frame') return { node, kind: 'frame' };
                    if ((kind === 'a' && attribute(node, 'href') !== null) || kind === 'summary') return { node, kind: 'link' };
                    if (matches(pressRoles, lower(attribute(node, 'role') ?? ''))) return { node, kind: 'button' };
                    if (kind === 'form' || kind === 'body' || kind === 'html') break;
                    node = up(node);
                }
                return { node: element, kind: 'plain' };
            };
            const nameOf = (node, kind) => {
                const label = attribute(node, 'aria-label');
                if (label) return tidy(label, 200);
                if (tag(node) === 'input') {
                    return tidy(read(valueOf, node) || attribute(node, 'alt') || attribute(node, 'title') || '', 200);
                }
                const words = shownText(node, 201);
                if (words.length > (kind === 'plain' ? 80 : 200)) return '';
                if (words) return words;
                let alt = '';
                each(node, 'img[alt]', (image) => { alt = tidy(attribute(image, 'alt'), 200); return alt !== ''; });
                return alt || tidy(attribute(node, 'title'), 200);
            };
            const amountsIn = (text, into) => {
                money.lastIndex = 0;
                for (let found = money.exec(text); found && into.length < 10; found = money.exec(text)) {
                    const amount = tidy(found[0], 60);
                    let seen = false;
                    for (let i = 0; i < into.length; i++) if (into[i] === amount) seen = true;
                    if (!seen) into[into.length] = amount;
                }
                return into;
            };
            /// The amounts shown for a press: in its name, else its form,
            /// else the nearest part of the page round it that shows any.
            const amountsFor = (node, name, form) => {
                const found = amountsIn(name, []);
                if (found.length) return found;
                if (form) return amountsIn(shownText(form, 5000), found);
                for (let at = up(node), depth = 0; at && depth < 6; at = up(at), depth++) {
                    const text = shownText(at, 3001);
                    if (text.length > 3000) break;
                    amountsIn(text, found);
                    if (found.length) break;
                }
                return found;
            };
            /// The button a form is sent with when Enter is pressed in it.
            const submitterOf = (form) => {
                const elements = read(elementsOf, form);
                const count = read(collectionLength, elements) ?? 0;
                for (let i = 0; i < count; i++) {
                    const element = apply(collectionItem, elements, [i]);
                    const found = control(element);
                    if (found.kind === 'submit' && found.node === element) return element;
                }
                return null;
            };
            const says = (name) => name !== '' && (matches(pay, name) || (matches(commits, name) && amountsIn(name, []).length > 0));

            return (element, how, key) => {
                const found = control(element);
                const node = found.node, kind = found.kind;
                const answer = (why, name, form) => ({ why, name, amounts: amountsFor(node, name, form), element: node });
                if (how === 'submit' || (how === 'key' && (kind === 'field' || kind === 'frame'))) {
                    if (how === 'key' && key !== 'Enter') return null;
                    const form = how === 'submit' && tag(node) === 'form' ? node : formOf(node);
                    if (kind === 'frame' && cardField(node)) return answer('card', '', form);
                    if (!form) return how === 'key' && nearCard(node) ? answer('card', '', null) : null;
                    if (holdsCard(form)) return answer('card', '', form);
                    const submitter = submitterOf(form);
                    const name = submitter ? nameOf(submitter, 'submit') : '';
                    return says(name) && !matches(never, name) ? answer('words', name, form) : null;
                }
                if (how === 'key' && key !== 'Enter' && key !== ' ') return null;
                if (kind === 'field' || kind === 'frame' || kind === 'other') return null;
                const name = nameOf(node, kind);
                if (matches(never, name)) return null;
                if (says(name)) return answer('words', name, formOf(node));
                if (kind === 'submit') {
                    const form = formOf(node);
                    if (form) return holdsCard(form) ? answer('card', name, form) : null;
                }
                if ((kind === 'submit' || kind === 'button') && nearCard(node)) return answer('card', name, null);
                return null;
            };
        }
        """#

    /// The helpers `weigher` takes, in the page model's world: nothing the
    /// page runs reaches it, so its built-ins are its own.
    nonisolated static let helpers = """
        const helpers = {
            apply: Reflect.apply, describe: Object.getOwnPropertyDescriptor,
            lower: (value) => String(value).toLowerCase(), matches: (regexp, value) => regexp.test(String(value)),
            pattern: (regexp) => regexp,
            tag: (node) => { try { return node.nodeType === 1 ? node.localName.toLowerCase() : ''; } catch { return ''; } },
            attribute: (element, name) => { try { return element.getAttribute(name); } catch { return null; } },
        };
        """
}

extension AgentPage {
    /// A press an agent makes: a click on an element, a click at a point of
    /// the screenshot, a key pressed (on an element, or where the keyboard
    /// is).
    enum Press {
        case element(String)
        case point(CGPoint, full: Bool)
        case key(AgentInput.Key, ref: String?)
    }

    /// What the press would pay, as the page weighs it; nil when it pays
    /// nothing.
    static func payment(_ press: Press, in agentTab: AgentTab) async throws -> AgentPayment? {
        let weighed: [String: Any]?
        switch press {
        case .element(let ref):
            weighed = try await weigh(ref, how: "click", key: "", in: agentTab)
        case .key(let key, let ref):
            // Return, the keypad's Enter, and Space: the keys that press.
            let name = key.code == 49 ? " " : [36, 76].contains(key.code) ? "Enter" : nil
            guard let name else { return nil }
            if let ref {
                weighed = try await weigh(ref, how: "key", key: name, in: agentTab)
            } else {
                weighed = try await weighFocused(key: name, in: agentTab)
            }
        case .point(let point, let full):
            weighed = try await weighAt(point, full: full, in: agentTab)
        }
        guard let weighed, let why = (weighed["why"] as? String).flatMap(AgentPayment.Reason.init) else { return nil }
        let described = weighed["what"]
        var what = describe(ref: nil, described)
        if case .element(let ref) = press { what = describe(ref: ref, described) }
        if what.isEmpty { what = "a button" }
        var element = weighed["key"] as? String ?? what
        if case .element(let ref) = press { element = ref }
        return AgentPayment(tab: agentTab, element: element, what: what, amounts: weighed["amounts"] as? [String] ?? [],
                            reason: why)
    }

    /// Weighs a press of the element `ref` names, in its own frame.
    private static func weigh(_ ref: String, how: String, key: String, in agentTab: AgentTab) async throws -> [String: Any]? {
        let element = try await element(ref, in: agentTab)
        return try await run(weighScript + "return weighed(element);", on: element, arguments: ["how": how, "pressed": key])
            as? [String: Any]
    }

    /// Weighs Enter or Space pressed where the keyboard is: the focused
    /// element, down frames of the same site and shadow roots; in a frame
    /// of another site, each such frame's own.
    private static func weighFocused(key: String, in agentTab: AgentTab) async throws -> [String: Any]? {
        guard let page = agentTab.tab.page else { return nil }
        let script = AgentPageScript.source + "\n" + weighScript + """
            let at = document.activeElement;
            for (let depth = 0; at && depth < 20; depth++) {
                if (at.shadowRoot && at.shadowRoot.activeElement) { at = at.shadowRoot.activeElement; continue; }
                if (/^i?frame$/i.test(at.localName)) {
                    let inner = null;
                    try { inner = at.contentDocument && at.contentDocument.activeElement; } catch {}
                    if (!inner) return { ...(weighed(at) || {}), otherSite: true };
                    at = inner;
                    continue;
                }
                break;
            }
            if (!at || at === document.body || at === document.documentElement) return null;
            return weighed(at);
            """
        let arguments: [String: Any] = ["op": "run", "args": [String: Any](), "prefix": "", "how": "key", "pressed": key]
        let main = try await page.callAsyncJavaScript(script, arguments: arguments, contentWorld: world) as? [String: Any]
        guard main?["otherSite"] as? Bool == true else { return main }
        // The keyboard is in a frame of another site: weighed there too.
        let tree = await frames(of: page)
        for frame in tree?.all.dropFirst() ?? [] {
            let inFrame = try? await page.callAsyncJavaScript(
                script, arguments: arguments, in: frame.info, contentWorld: world
            ) as? [String: Any]
            if inFrame?["why"] != nil { return inFrame }
        }
        return main?["why"] != nil ? main : nil
    }

    /// Weighs a click at a point of the tab's screenshot: on what is there,
    /// down frames of the same site and shadow roots.
    private static func weighAt(_ point: CGPoint, full: Bool, in agentTab: AgentTab) async throws -> [String: Any]? {
        guard let page = agentTab.tab.page, let window = page.window, page.bounds.width > 0 else { return nil }
        let imageWidth = full ? page.bounds.width * window.backingScaleFactor : CGFloat(AgentShot.width)
        let scale = page.bounds.width / imageWidth / (page.pageZoom * page.magnification)
        let script = AgentPageScript.source + "\n" + weighScript + """
            let root = document, x = pointX, y = pointY, at = null;
            for (let depth = 0; root && depth < 20; depth++) {
                at = root.elementFromPoint(x, y);
                while (at && at.shadowRoot) {
                    const inner = at.shadowRoot.elementFromPoint(x, y);
                    if (!inner || inner === at) break;
                    at = inner;
                }
                if (!at || !/^i?frame$/i.test(at.localName)) break;
                let inner = null;
                try { inner = at.contentDocument; } catch {}
                if (!inner) break;
                const box = at.getBoundingClientRect();
                x -= box.left + at.clientLeft;
                y -= box.top + at.clientTop;
                root = inner;
            }
            return at ? weighed(at) : null;
            """
        return try await page.callAsyncJavaScript(
            script, arguments: ["op": "run", "args": [String: Any](), "prefix": "", "how": "click", "pressed": "",
                                "pointX": point.x * scale, "pointY": point.y * scale],
            contentWorld: world
        ) as? [String: Any]
    }

    /// Defines `weighed(element)`: the weigher's answer for a press of it
    /// (`how`, `pressed`), with how the outline names what is pressed
    /// (`what`) and a key for it (`key`: its ref, or its role and name).
    private static let weighScript = AgentPayments.helpers + """
        const weighed = (target) => {
            const view = target.ownerDocument.defaultView;
            const verdict = (\(AgentPayments.weigher))(view, helpers)(target, how, pressed);
            if (!verdict) return null;
            const what = nerdaAgent.describe(verdict.element);
            if (!what.name && verdict.name) what.name = verdict.name;
            return { why: verdict.why, amounts: verdict.amounts, what,
                     key: what.ref || ((what.role || verdict.element.localName) + ' ' + (what.name || verdict.name)) };
        };

        """
}

nonisolated extension AgentEvalGuard {
    /// A payment pressed from eval refused, telling the agent to press it
    /// with click, which holds it for the owner's Touch ID (a script can't
    /// wait for that): `click()`, an event sent (click, the mouse or
    /// pointer pressed, Enter or Space, submit), a form sent with `submit`
    /// or `requestSubmit`, weighed as the page model weighs a press
    /// (`AgentPayments.weigher`). First of the parts, so it weighs with
    /// the values and keys as they are; it leaves `submit` configurable
    /// for the next part to wrap too.
    static let payments = #"""
        (win, guard) => {
            const { apply, describe, refuse, tag } = guard;
            const weigh = (\#(AgentPayments.weigher))(win, guard);
            const held = (element, how, key) => {
                let verdict;
                try { verdict = weigh(element, how, key); } catch {
                    refuse("press this, as Nerda couldn't tell whether it pays: click it with the click verb instead");
                }
                if (!verdict) return;
                const name = verdict.name ? '“' + verdict.name + '”' : 'a ' + (verdict.why === 'card' ? 'form with card fields' : 'payment');
                let amounts = '';
                for (let i = 0; i < verdict.amounts.length && i < 3; i++) amounts += (i ? ', ' : ' ') + verdict.amounts[i];
                refuse('press a payment (' + name + amounts + '): press it with the click or press verb, ' +
                       'which waits for the user to approve it with Touch ID');
            };
            guard.method(win.HTMLElement.prototype, 'click', (self) => held(self, 'click', ''));
            guard.method(win.HTMLFormElement.prototype, 'requestSubmit', (self, args) => {
                if (args.length > 0 && args[0] !== null && args[0] !== undefined) held(args[0], 'click', '');
                held(self, 'submit', '');
            });
            // Left configurable: the password part wraps it again, then fixes it.
            const submit = describe(win.HTMLFormElement.prototype, 'submit');
            if (submit && typeof submit.value === 'function') {
                const original = submit.value;
                guard.define(win.HTMLFormElement.prototype, 'submit', { configurable: true, writable: false, enumerable: submit.enumerable,
                    value: { submit() { held(this, 'submit', ''); return apply(original, this, []); } }.submit });
            }
            const typeOf = describe(win.Event.prototype, 'type').get;
            const keyOf = describe(win.KeyboardEvent.prototype, 'key').get;
            const pointing = { __proto__: null, click: 1, dblclick: 1, auxclick: 1, mousedown: 1, mouseup: 1, pointerdown: 1, pointerup: 1, touchstart: 1, touchend: 1 };
            const keys = { __proto__: null, keydown: 1, keypress: 1, keyup: 1 };
            guard.method(win.EventTarget.prototype, 'dispatchEvent', (self, args) => {
                let type = '';
                try { type = apply(typeOf, args[0], []); } catch { return; }
                if (pointing[type] === 1) held(self, 'click', '');
                else if (type === 'submit') held(self, 'submit', '');
                else if (keys[type] === 1) {
                    let key = '';
                    try { key = apply(keyOf, args[0], []); } catch { return; }
                    if (key === 'Enter' || key === ' ' || key === 'Spacebar') held(self, 'key', key === 'Enter' ? 'Enter' : ' ');
                }
            });
        }
        """#
}
