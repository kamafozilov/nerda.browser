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

/// What was just sent from a sign-in box, held until it is known whether it
/// worked: only a password that got someone in is worth offering to keep.
struct SentSignIn: Equatable {
    let host: String
    let user: String
    let password: String
    /// Sent from a page that came over plain http.
    let clear: Bool
    let at: Date

    /// Long enough for a slow sign-in to land; past that, the page moving on
    /// is not its doing.
    var isRecent: Bool { Date.now.timeIntervalSince(at) < 45 }
}

/// The saved accounts that could go in the sign-in box the caret is in, or
/// the addresses or cards for the form box it is in (AutoFill.swift), and
/// where that box is on the page (in points, from the page's top left).
struct PasswordChoices: Equatable {
    let tab: Tab.ID
    let site: String
    /// Listed for a page that came over plain http.
    let clear: Bool
    /// Moved (the page scrolled, or put the caret in another box): the
    /// list starts again as if just shown.
    var spot: CGRect { didSet { if spot != oldValue { shown = .now } } }
    var accounts: [Account]
    var addresses: [Contact] = []
    var cards: [Card] = []
    /// When it came up where it is. A page can put the caret in a sign-in
    /// box itself, an invisible one under the pointer included, or move the
    /// box there: a click that was already on its way is not a choice, so
    /// the list takes none for its first half second, as Chrome's does.
    var shown = Date.now
    var frame: WKFrameInfo? = nil

    var takesClicks: Bool { Date.now.timeIntervalSince(shown) > 0.5 }
    var isEmpty: Bool { accounts.isEmpty && addresses.isEmpty && cards.isEmpty }
}

/// A sign-in that worked, not yet kept: with its password, or with a
/// service (`account.provider`) and an empty password.
struct PasswordOffer: Equatable {
    let tab: Tab.ID
    let account: Account
    let password: String
    /// From a page that came over plain http.
    let clear: Bool
    /// This name has a password kept here already, a different one.
    let replaces: Bool
}

/// The page's side, in Nerda's own script world: the page can't see it, call
/// it, or talk to the browser in its name. That world is in every frame
/// already; one of its own would be another in each frame, ads' included.
/// Each frame is checked against its own security origin, and a picked
/// password goes back to that frame only.
enum Passwords {
    static let world = WKContentWorld.defaultClient
    static let messages = Messages()

    static func install(in controller: WKUserContentController, nativePasskeys: Bool = Passkeys.available) {
        controller.addUserScript(WKUserScript(source: starter, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: SocialSignIn.chooser, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        controller.add(messages, contentWorld: world, name: "passwords")
        if !nativePasskeys {
            controller.addUserScript(WKUserScript(source: withoutPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }

    /// Without Apple's browser entitlement, WebKit
    /// says no passkey is to be had, yet leaves the passkey object there, so
    /// sites go for the passkey first and leave you stuck on it. Without the
    /// object they ask for the password straight away. navigator.credentials
    /// itself stays, as sites use it for passwords too. The object is gone
    /// altogether, not only empty: sites look for it with `in` as well, and
    /// one that finds the name and then reads undefined fails to load
    /// (Stencil's sign-in).
    ///
    /// Unless an extension answers passkey requests itself, as a password
    /// manager with your passkeys in it does: it puts its own get and create
    /// on navigator.credentials, and from then on sites see the object and
    /// ask the extension. One that brings its own object puts it there itself.
    /// Any request it leaves to Nerda is turned down at once, as if you had
    /// said no, where WebKit would try and fail. After Search's.
    static let withoutPasskeys = #"""
        (() => {
            const real = window.PublicKeyCredential;
            if (!real) return;
            try { delete window.PublicKeyCredential; } catch {}
            if ('PublicKeyCredential' in window) return;
            const claim = () => { if (!('PublicKeyCredential' in window)) window.PublicKeyCredential = real; };
            const proto = CredentialsContainer.prototype;
            for (const name of ['get', 'create']) {
                const native = proto[name];
                const ours = function (options) {
                    if (!options?.publicKey) return native.apply(this, arguments);
                    // Asked for under the name box: nothing to offer, so it
                    // waits, as it would while nobody picks one, until the page lets it go.
                    if (name === 'get' && options.mediation === 'conditional') {
                        return new Promise((resolve, reject) => {
                            const signal = options.signal;
                            if (!signal) return;
                            const aborted = () => signal.reason ?? new DOMException('The operation was aborted.', 'AbortError');
                            if (signal.aborted) return reject(aborted());
                            signal.addEventListener('abort', () => reject(aborted()), { once: true });
                        });
                    }
                    return Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
                };
                try {
                    // An extension's own, set on navigator.credentials, lands
                    // there, and brings the object back.
                    Object.defineProperty(proto, name, {
                        configurable: true,
                        get: () => ours,
                        set(value) {
                            Object.defineProperty(this, name, { configurable: true, enumerable: true, writable: true, value });
                            claim();
                        },
                    });
                } catch {}
            }
        })();
        """#

    /// What every frame gets: the rest (`source`) is sent for only once the
    /// frame has a form or a password box, or a box is gone to or a form sent
    /// first. Most frames (ads, widgets) never have one, and the whole script
    /// was read and run in each of them. What happened before the rest came
    /// is kept for it: the box gone to, and a form sent. Whether the page asks
    /// for a password is answered here: the browser asks it of each new page,
    /// sent for the rest or not.
    private static let starter = #"""
        (() => {
            \#(boxes)
            window.nerdaAsksForPassword = () => passwords().length > 0;
            const early = window.nerdaPasswordsEarly = { box: null, sent: false, edited: false };
            let asked = false;
            const load = () => {
                if (asked) return;
                asked = true;
                window.webkit.messageHandlers.passwords.postMessage({ kind: 'load' });
            };
            const field = (box) => box instanceof HTMLInputElement || box instanceof HTMLTextAreaElement || box instanceof HTMLSelectElement;
            const focused = (event) => {
                if (!field(event.target)) return;
                early.box = event.target;
                load();
            };
            const sending = () => {
                early.sent = true;
                load();
            };
            const clicked = (event) => {
                if (event.isTrusted && event.target.closest?.('button, input[type=submit], input[type=button], [role=button]')) sending();
            };
            // Whether anything was typed, picked or filled in since the page
            // loaded: until then a click sends nothing worth looking through
            // the boxes for. Kept on after the rest has come, which reads it.
            const edited = () => {
                early.edited = true;
                removeEventListener('input', edited, true);
                removeEventListener('change', edited, true);
            };
            addEventListener('input', edited, true);
            addEventListener('change', edited, true);
            addEventListener('focusin', focused, true);
            addEventListener('submit', sending, true);
            addEventListener('click', clicked, true);
            early.stop = () => {
                removeEventListener('focusin', focused, true);
                removeEventListener('submit', sending, true);
                removeEventListener('click', clicked, true);
            };
            if (document.activeElement instanceof HTMLInputElement || document.forms.length || document.querySelector('input[type=password]')) load();
        })();
        """#

    /// What tells a password box, for both `starter` and `source`.
    private static let boxes = #"""
        const shown = (box) => {
            const r = box.getBoundingClientRect();
            return r.width > 0 && r.height > 0 && getComputedStyle(box).visibility !== 'hidden';
        };
        const usable = (box) => box instanceof HTMLInputElement && !box.disabled && !box.readOnly && shown(box);
        const isPassword = (box) => box instanceof HTMLInputElement && box.type === 'password' && usable(box);
        const passwords = (scope = document) => [...scope.querySelectorAll('input[type=password]')].filter(isPassword);
        """#

    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard ["http", "https"].contains(origin.protocol), !origin.host.isEmpty,
                  let page = message.webView, let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            // Into the frame that asked, in the world it asked from.
            if kind == "load" { return page.evaluateJavaScript(source, in: message.frameInfo, in: world) }
            (page.uiDelegate as? Browser)?.page(page, passwords: kind, body, host: Site.key(origin.host),
                                                clear: origin.protocol == "http", frame: message.frameInfo)
        }
    }

    /// Whether a password that got someone in is offered to keep, and saved
    /// accounts are listed under a sign-in box (Settings › Passwords).
    static let offersKey = "offersToSavePasswords"
    static let fillsKey = "fillsPasswords"
    static var offers: Bool { UserDefaults.standard.object(forKey: offersKey) as? Bool ?? true }
    static var fills: Bool { UserDefaults.standard.object(forKey: fillsKey) as? Bool ?? true }

    /// Sites told never to ask about, by site.
    static var never: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "passwordsNeverSaved") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "passwordsNeverSaved") }
    }

    /// The rest, sent for by `starter`, once a document.
    private static let source = #"""
        (() => {
            if (window.nerdaFill) return;
            const early = window.nerdaPasswordsEarly;
            early?.stop();
            const post = (message) => window.webkit.messageHandlers.passwords.postMessage(message);
            \#(boxes)
            const isName = (box) => box instanceof HTMLInputElement && ['text', 'email', 'tel'].includes(box.type) && usable(box);
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

            \#(AutoFill.classifier)
            \#(SocialSignIn.button)
            // The boxes an address or card goes in: lists and text areas too.
            const fillable = (box) => (box instanceof HTMLInputElement ? ['text', 'email', 'tel', 'number'].includes(box.type) && !box.readOnly
                : box instanceof HTMLTextAreaElement ? !box.readOnly : box instanceof HTMLSelectElement) && !box.disabled && shown(box);
            // What a box's label says, without the text of a list inside it (every country's name).
            const labelled = (label) => {
                const copy = label.cloneNode(true);
                copy.querySelectorAll('input, select, textarea').forEach((inside) => inside.remove());
                return copy.textContent.slice(0, 200);
            };
            const classify = (box) => autofillToken(box.getAttribute('autocomplete'),
                [box.name, box.id, box.placeholder, box.getAttribute('aria-label'), ...[...(box.labels ?? [])].map(labelled)].join(' '),
                box.type);
            const kindOf = (token) => token?.startsWith('cc-') ? 'card' : token ? 'address' : null;
            // The boxes of one address or one card in the form around a box,
            // with what each takes: its run of them, which ends where a kind of
            // box comes round again (a billing address after a shipping one).
            const group = (box, kind) => {
                const groups = [[]];
                for (const other of (box.form ?? document).querySelectorAll('input, select, textarea')) {
                    if (!fillable(other)) continue;
                    const token = classify(other);
                    if (kindOf(token) !== kind) continue;
                    if (groups.at(-1).some((field) => field.token === token)) groups.push([]);
                    groups.at(-1).push({ box: other, token });
                }
                return groups.find((fields) => fields.some((field) => field.box === box)) ?? [];
            };
            // Whether the box the caret is in lists addresses or cards: a card's
            // box in a form with its number, over https; an address's box with
            // another beside it, or one the page itself said takes a name, an
            // email, a phone.
            const formKind = (box) => {
                if (box instanceof HTMLSelectElement || !fillable(box)) return null;
                const kind = kindOf(classify(box));
                const fields = kind ? group(box, kind) : [];
                if (kind === 'card') return location.protocol === 'https:' && fields.some((field) => field.token === 'cc-number') ? kind : null;
                const named = autofillTokens.includes(box.getAttribute('autocomplete')?.toLowerCase().split(/\s+/).at(-1));
                return kind && (fields.length > 1 || named) ? kind : null;
            };

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
                // A sign-in's boxes are the passwords', whatever else they look like.
                const form = isPassword(box) || (isName(box) && passwordFor(box) !== null) ? null : formKind(box);
                if (!form && !isField(box)) {
                    field = null;
                    return unlist('blur');
                }
                field = box;
                if (form) {
                    if (box.value) return unlist('blur');
                    listed = true;
                    return post({ kind: 'focus', spot: spot(), form });
                }
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
            // The page put the caret in a box before this was here, or the
            // person did, which sent for it.
            const active = document.activeElement;
            if (active instanceof HTMLInputElement || (active && active === early?.box)) arrive(active);
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

            // The address and card a page's forms hold as they are sent: the
            // first of each kind of box with something in it.
            const formSent = () => {
                const sent = {};
                // Said on every click of a button: the cheap checks first, laying
                // out only a box that holds something AutoFill keeps.
                for (const box of document.querySelectorAll('input, select, textarea')) {
                    const number = box instanceof HTMLSelectElement && /^\d+$/.test(box.value);
                    const value = (box instanceof HTMLSelectElement && !number ? box.selectedOptions[0]?.text ?? '' : box.value).trim();
                    if (!value) continue;
                    const token = classify(box);
                    const kind = kindOf(token);
                    if (!kind || !fillable(box)) continue;
                    sent[kind] ??= {};
                    sent[kind][token] ??= value;
                }
                if (sent.address || sent.card) post({ kind: 'form', ...sent });
            };

            // What the boxes hold as they are sent, said on every way of sending
            // them; the browser keeps the last.
            const sent = () => {
                formSent();
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
            // Plenty of sign-in buttons are in no form, and never send one. Most
            // clicks are on pages where nothing was filled in: their boxes, in
            // the page and every frame, aren't looked through for each.
            addEventListener('click', (event) => {
                if (early?.edited === false) return;
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

            // As if typed: WebKit's own setter from this world, which the page's
            // frameworks don't watch, so the input event after it reads as news.
            const put = (box, value) => {
                box.focus();
                box.value = value;
                box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
                box.dispatchEvent(new Event('change', { bubbles: true }));
            };
            // Into the boxes the caret was in, and only on the site it was picked
            // for, over https if it was listed for a page over https.
            window.nerdaFill = (user, password, site, secure) => {
                if (location.hostname.toLowerCase().replace(/^www\./, '') !== site) return false;
                if (secure && location.protocol !== 'https:') return false;
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

            // A list's option for a value: the same, the same number (4 for 04,
            // 27 for 2027), or else the first whose text starts with it.
            const choose = (select, value) => {
                const want = value.toLowerCase();
                const number = /^\d+$/.test(want) ? Number(want) : null;
                const options = [...select.options].filter((option) => !option.disabled);
                const option = options.find((option) => [option.value, option.text].some((text) => text.trim().toLowerCase() === want))
                    ?? (number === null ? undefined : options.find((option) => option.value.trim() !== '' && [number, number % 100].includes(Number(option.value))))
                    ?? (want.length > 1 ? options.find((option) => option.text.trim().toLowerCase().startsWith(want)) : undefined);
                if (!option || option.selected) return;
                select.value = option.value;
                select.dispatchEvent(new Event('input', { bubbles: true }));
                select.dispatchEvent(new Event('change', { bubbles: true }));
            };
            // What goes in a box, as it takes it: a street on one line, an
            // expiry as MM/YY, or MM/YYYY where the page asks for that.
            const valueFor = (box, token, values) => {
                if (token === 'street-address' && !(box instanceof HTMLTextAreaElement)) return values[token]?.replace(/\n/g, ', ');
                const year = values['cc-exp-year'];
                if (token === 'cc-exp') {
                    const month = values['cc-exp-month'];
                    const hint = `${box.placeholder} ${box.getAttribute('aria-label') ?? ''}`.toLowerCase();
                    if (!month || !year) return null;
                    return `${month}${hint.includes(' / ') ? ' / ' : '/'}${/yyyy|aaaa/.test(hint) ? year : year.slice(2)}`;
                }
                if (token === 'cc-exp-year' && (box.maxLength === 2 || /^\s*yy\s*$/i.test(box.placeholder ?? ''))) return year?.slice(2);
                return values[token];
            };
            // An address or card picked under one of a form's boxes, into each
            // box of its group the page left empty, and its lists. Only on the
            // site it was listed for; a card, or anything listed for a page
            // over https, only over https.
            window.nerdaFillForm = (kind, values, site, secure) => {
                if (location.hostname.toLowerCase().replace(/^www\./, '') !== site) return false;
                if ((secure || kind === 'card') && location.protocol !== 'https:') return false;
                const box = field?.isConnected ? field : null;
                if (!box) return false;
                listed = false;
                filling = true;
                try {
                    for (const { box: other, token } of group(box, kind)) {
                        const value = valueFor(other, token, values);
                        if (!value) continue;
                        if (other instanceof HTMLSelectElement) choose(other, value);
                        else if (other === box || !other.value) put(other, value);
                    }
                    box.focus();
                } finally {
                    filling = false;
                }
                return true;
            };

            // A form sent before this was here: what its boxes hold is still in them.
            if (early?.sent) sent();
        })();
        """#
}

extension Browser {
    /// What a page's sign-in boxes say, from `Passwords.Messages`.
    /// `clear`: the page came over plain http.
    func page(_ page: WKWebView, passwords kind: String, _ body: [String: Any], host: String, clear: Bool,
              frame: WKFrameInfo? = nil) {
        guard let tab = tab(for: page) else { return }
        switch kind {
        case "focus":
            // A box of a form takes an address or a card, on the page's own frames only.
            let form = body["form"] as? String
            let fills = switch form {
            case nil: Passwords.fills
            case "card": AutoFill.fillsCards && !clear && Self.isPagesOwn(frame, on: tab)
            default: AutoFill.fillsAddresses && Self.isPagesOwn(frame, on: tab)
            }
            guard fills, let spot = Self.spot(body, on: page, frame: frame) else { return }
            choicesAsked += 1
            let asked = choicesAsked
            Task {
                var choices = PasswordChoices(tab: tab.id, site: host, clear: clear, spot: spot, accounts: [], frame: frame)
                switch form {
                case "address": choices.addresses = Array(profile.autofill.addresses.prefix(6))
                case "card": choices.cards = Array(profile.autofill.cards.prefix(6))
                default: choices.accounts = Array(await vault.accounts(for: host, clear: clear).prefix(6))
                }
                // Gone meanwhile: the caret moved on, or the tab did.
                guard asked == choicesAsked, tab.id == selectedID else { return }
                passwordChoices = choices.isEmpty ? nil : choices
            }
        case "move":
            guard passwordChoices?.tab == tab.id, passwordChoices?.site == host,
                  let spot = Self.spot(body, on: page, frame: frame) else { return }
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
            tab.signIn = SentSignIn(host: host, user: user, password: password, clear: clear, at: .now)
            hideChoices(on: tab)
        case "gone":
            guard let sent = tab.signIn, sent.isRecent, sent.host == host else { return }
            tab.signIn = nil
            offer(sent, on: tab)
        case "form":
            self.page(page, sentForm: body, on: tab, clear: clear, frame: frame)
        default:
            break
        }
    }

    /// A new page is in: if it came after a password went out, and asks for
    /// none itself, that sign-in worked. One that asks again was refused, or
    /// is the next step of the same sign-in. One with another service is
    /// watched for as well (`socialLanded`).
    func signInLanded(on tab: Tab) {
        socialLanded(on: tab)
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
        // A password manager extension that saves passwords itself asked
        // Nerda not to offer (chrome.privacy), as it asks Chrome.
        guard Passwords.offers, !Passwords.never.contains(Site.of(sent.host)), Extensions.shared.passwordSavingTakenBy == nil else { return }
        Task {
            guard let (known, replaces) = await vault.check(sent), !known,
                  tabs.contains(where: { $0 === tab }) else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                passwordOffer = PasswordOffer(tab: tab.id, account: Account(host: sent.host, user: sent.user),
                                              password: sent.password, clear: sent.clear, replaces: replaces)
            }
        }
    }

    /// Kept, under the user name as the offer shows it, changed there or not.
    func keepOfferedPassword(as user: String? = nil) {
        guard let offer = passwordOffer else { return }
        dropPasswordOffer()
        let named = user.map { $0.trimmingCharacters(in: .whitespaces) } ?? offer.account.user
        let account = Account(host: offer.account.host, user: named, provider: offer.account.provider)
        Task {
            if await !vault.save([(account, offer.password)], clear: offer.clear) {
                Self.tell(account.provider == nil ? "Couldn't save the password" : "Couldn't save the sign-in", "The keychain didn't take it.")
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

    /// One of the accounts listed, into the page it was listed on; a sign-in
    /// with another service, by the site's button for it.
    func fill(_ account: Account) {
        guard let (choices, page) = takeChoice() else { return }
        if let provider = SocialSignIn.provider(account.provider) {
            return signIn(with: provider, as: account, choices, on: page)
        }
        Task {
            // nil when the Mac was asked whether Nerda may read it, and said no.
            guard let password = await vault.password(for: account) else { return }
            let filled = try? await page.callAsyncJavaScript(
                "return nerdaFill(user, password, site, secure)",
                arguments: ["user": account.user, "password": password, "site": choices.site, "secure": !choices.clear],
                in: choices.frame,
                contentWorld: Passwords.world
            ) as? Bool
            page.window?.makeFirstResponder(page)
            if filled == true { await vault.touch([account]) }
        }
    }

    /// What was listed, and the page it was listed on, as one is picked;
    /// nil for a pick the list takes no click for yet.
    func takeChoice() -> (PasswordChoices, WKWebView)? {
        guard let choices = passwordChoices, choices.takesClicks,
              let page = tabs.first(where: { $0.id == choices.tab })?.page else { return nil }
        choicesAsked += 1
        passwordChoices = nil
        return (choices, page)
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

    static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Where the box is, from the page's CSS pixels to points.
    private static func spot(_ body: [String: Any], on page: WKWebView, frame: WKFrameInfo? = nil) -> CGRect? {
        // A cross-origin frame cannot reveal its position. Keep its account
        // picker in the browser's page corner, labelled with the frame's site.
        if frame?.isMainFrame == false { return CGRect(x: 12, y: 12, width: 280, height: 0) }
        guard let spot = body["spot"] as? [String: Double], let x = spot["x"], let y = spot["y"],
              let width = spot["width"], let height = spot["height"] else { return nil }
        let zoom = page.pageZoom
        return CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
    }
}

