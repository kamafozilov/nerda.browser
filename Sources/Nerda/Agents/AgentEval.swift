import Foundation
import WebKit

/// Agent `eval`: JavaScript an agent runs in an Agent tab's page, in an
/// isolated world of its own (`world`): it shares the page's document, not
/// the page's script, nor the page model's world (`AgentPage.world`), nor
/// `.defaultClient`, where Nerda's passwords and `nerdaFill` live.
///
/// Before any of the agent's code runs in a realm of that world (the page's
/// document, or a frame of the same site), a guard is set up in it and
/// frozen (`AgentEvalGuard`): password and card values read as `••••`, and
/// the ways of running code in the page's own world, where they don't, are
/// refused, and so is pressing a payment (`AgentEvalGuard.payments`), which
/// only `click` and `press` hold for the owner's Touch ID. Its parts are
/// listed in `AgentEvalGuard.parts`.
///
/// The guard is no sandbox. WebKit runs a `javascript:` address set
/// through `location` in the page's own world, with no navigation policy
/// asked and no way for script to change `location`; and a frame's
/// document that replaces one the guard was set up in is reached through
/// `window[0]` before it is guarded. Script determined to get round it
/// can; what it stops is the plain read and the common ways round it.
@MainActor
enum AgentEval {
    static let world = WKContentWorld.world(name: "nerda-agents-eval")

    /// The most characters of a result answered.
    static let mostResult = 40_000

    /// Runs `code` as the body of an async function in the tab's page, and
    /// answers what it returned as JSON (nil for nothing). Fails with what
    /// it threw, or when a dialog comes up or the deadline passes first.
    static func run(_ code: String, in agentTab: AgentTab, by deadline: ContinuousClock.Instant) async throws -> String? {
        guard let page = agentTab.tab.page else {
            throw AgentError(.failed, "Tab \(agentTab.ref) has no page to run script in.")
        }
        let outcome = await AgentPage.unlessHeld(agentTab.tab, by: deadline) { () -> Result<String?, any Error> in
            do {
                let value = try await page.callAsyncJavaScript(
                    AgentEvalGuard.body, arguments: ["code": code, "most": mostResult], in: nil, contentWorld: world
                )
                return .success(value as? String)
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let value)?:
            return value
        case .failure(let error)?:
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            throw AgentError(.failed, "eval threw: \(message.replacing(/\s+/, with: " "))")
        case nil:
            if let held = PageNotices.held(agentTab.tab) {
                throw AgentError(.failed, "eval didn't finish: the page raised a dialog (\(held)) and waits on it.")
            }
            throw AgentError(.timedOut, "eval didn't finish in time.")
        }
    }
}

/// The guard agent `eval` runs inside, as JavaScript for `AgentEval.world`.
///
/// `body` is what each eval runs: it sets the guard up in the page's realm
/// unless it already is (a property of the window's that can't be changed
/// once made: no agent code runs in a realm before its guard), sets it up
/// in each frame of the same site it can reach, then compiles the agent's
/// code (passed as a string, never pasted into this body, so nothing in it
/// can come first) and runs it.
///
/// Each part is a function `(win, guard)` called once per realm (`win`, a
/// window of that world), patching that realm's prototypes through
/// `guard.method`, `guard.setter` and `guard.getter`, which make each patch
/// non-configurable. Parts run again for frames the agent reaches later,
/// after its code may have changed this realm's built-ins, so they use only
/// what `guard` captured at the start: `guard.apply`, `guard.lower`,
/// `guard.matches`, `guard.tag`, `guard.attribute`, index loops, never
/// iterators or array methods.
nonisolated enum AgentEvalGuard {
    /// What the guard is made of, in order: payments first, to weigh
    /// presses with values and keys as they are (`AgentPayments.weigher`).
    static let parts = [payments, passwords, pageScript, frames]

    static var body: String {
        """
        if (!window.nerdaEvalGuard) {
        \(prelude)
        install(window);
        }
        const guard = window.nerdaEvalGuard;
        guard.reach(window);
        return await guard.run(code, most);
        """
    }


    /// What the parts share: built-ins captured before any agent code runs,
    /// the tests for secret fields, the patching helpers, `install` and
    /// `run`. Ends having defined `install(win)`.
    static var prelude: String {
        #"""
        const install = (() => {
            const O = Object, R = Reflect, Str = String, Err = Error, WS = WeakSet, WM = WeakMap;
            const apply = R.apply, construct = R.construct, defineProperty = O.defineProperty, describe = O.getOwnPropertyDescriptor;
            const hasOwn = O.prototype.hasOwnProperty, freeze = O.freeze;
            const wsHas = WS.prototype.has, wsAdd = WS.prototype.add, wmGet = WM.prototype.get, wmSet = WM.prototype.set;
            const lowerCase = Str.prototype.toLowerCase, slice = Str.prototype.slice, indexOf = Str.prototype.indexOf;
            const exec = RegExp.prototype.exec, test = RegExp.prototype.test;
            const stringify = JSON.stringify;
            const AsyncFunction = (async function () {}).constructor;
            const getAttribute = Element.prototype.getAttribute;
            const localName = describe(Element.prototype, 'localName').get;
            const nodeType = describe(Node.prototype, 'nodeType').get;

            /// A pattern that keeps its own exec, whatever is done to RegExp later.
            const pattern = (regexp) => { defineProperty(regexp, 'exec', { value: exec }); return regexp; };
            const text = (value) => Str(value);
            const lower = (value) => apply(lowerCase, Str(value), []);
            const local = (name) => {
                const all = lower(name);
                const at = apply(indexOf, all, [':']);
                return at < 0 ? all : apply(slice, all, [at + 1]);
            };
            const matches = (regexp, value) => apply(test, regexp, [Str(value)]);
            const tag = (node) => {
                try { return apply(nodeType, node, []) === 1 ? lower(apply(localName, node, [])) : ''; } catch { return ''; }
            };
            const attribute = (element, name) => { try { return apply(getAttribute, element, [name]); } catch { return null; } };
            const refuse = (what) => { throw new Err("Nerda doesn't let eval " + what + '.'); };
            /// An address that runs script where it is opened: in the page's world.
            const javascript = pattern(/^[\u0000- ]*j[\t\n\r]*a[\t\n\r]*v[\t\n\r]*a[\t\n\r]*s[\t\n\r]*c[\t\n\r]*r[\t\n\r]*i[\t\n\r]*p[\t\n\r]*t[\t\n\r]*:/i);

            /// Inputs seen as password boxes stay so, whatever their type becomes.
            const passwordBoxes = new WS();
            const isPasswordBox = (element) => {
                if (tag(element) !== 'input') return false;
                if (apply(wsHas, passwordBoxes, [element])) return true;
                if (lower(attribute(element, 'type') ?? '') !== 'password') return false;
                apply(wsAdd, passwordBoxes, [element]);
                return true;
            };
            const secretWords = pattern(/pass(word|code|phrase)?|card.?(number|num|no)|cc.?(num|number)|credit.?card|\bcvc|cvv|cvn|\bcsc\b|security.?code|card.?code|seed|mnemonic|recovery.?(phrase|key|words)|private.?key|secret|api.?key|access.?key|token|\biban\b/i);
            const secretComplete = pattern(/\bcc-(number|csc|exp|exp-month|exp-year)\b|current-password|new-password/);
            /// Fields whose values never reach an agent: passwords, cards,
            /// seed phrases, keys (as the page model masks them).
            const secret = (element) => {
                const kind = tag(element);
                if (kind !== 'input' && kind !== 'textarea') return false;
                if (isPasswordBox(element)) return true;
                if (matches(secretComplete, lower(attribute(element, 'autocomplete') ?? ''))) return true;
                return matches(secretWords, attribute(element, 'name') + ' ' + attribute(element, 'id') + ' ' +
                    attribute(element, 'aria-label') + ' ' + attribute(element, 'placeholder') + ' ' + attribute(element, 'data-testid'));
            };

            const fix = (owner, name, property) => {
                property.configurable = false;
                defineProperty(owner, name, property);
            };
            /// Wraps a method: `before(self, args)` may refuse or change the
            /// arguments; `after(self, args, result)` answers what to return.
            const method = (owner, name, before, after) => {
                const was = owner && describe(owner, name);
                if (!was || typeof was.value !== 'function') return;
                const original = was.value;
                const wrapped = { [name](...args) {
                    if (before) before(this, args);
                    const result = apply(original, this, args);
                    return after ? after(this, args, result) : result;
                } }[name];
                fix(owner, name, { value: wrapped, writable: false, enumerable: was.enumerable });
            };
            /// Wraps a setter: `before(self, value)` may refuse, and answers
            /// the value to set (converted once, so it can't change between).
            const setter = (owner, name, before) => {
                const was = owner && describe(owner, name);
                if (!was || !was.set) return;
                const set = was.set;
                fix(owner, name, { get: was.get, enumerable: was.enumerable,
                    set: { [name](value) { apply(set, this, [before(this, value)]); } }[name] });
            };
            /// Wraps a getter: `after(self, value)` answers what is read.
            const getter = (owner, name, after) => {
                const was = owner && describe(owner, name);
                if (!was || !was.get) return;
                const get = was.get;
                fix(owner, name, { set: was.set, enumerable: was.enumerable,
                    get: { [name]() { return after(this, apply(get, this, [])); } }[name] });
            };

            const parts = [
        \#(parts.joined(separator: ",\n"))
            ];
            const count = parts.length;
            /// Each guarded realm's own way to read how many frames it has.
            const lengths = new WM();
            let guard;
            /// Sets the guard up in a realm (a window of this world), once.
            const install = (win) => {
                try {
                    if (!win || apply(hasOwn, win, ['nerdaEvalGuard']) || !win.HTMLElement) return;
                } catch { return; } // a frame of another site: nothing of it can be read
                const length = describe(win, 'length');
                if (length && length.get) apply(wmSet, lengths, [win, length.get]);
                for (let i = 0; i < count; i++) parts[i](win, guard);
                defineProperty(win, 'nerdaEvalGuard', { value: guard, writable: false, configurable: false, enumerable: false });
            };
            /// Sets the guard up in every frame of this window it can reach.
            const reach = (win) => {
                let length = 0;
                try {
                    const get = apply(wmGet, lengths, [win]);
                    length = get ? apply(get, win, []) : win.length;
                } catch { return; }
                for (let i = 0; i < length; i++) {
                    let child;
                    try { child = win[i]; } catch { continue; }
                    install(child);
                    reach(child);
                }
            };
            /// A value as an agent is shown it: JSON, elements as their tag,
            /// id and start of text, at most `most` characters.
            const show = (value, most) => {
                if (value === undefined) return null;
                const seen = new WS();
                let shown;
                try {
                    shown = apply(stringify, JSON, [value, function (key, item) {
                        if (typeof item === 'function') return '[function]';
                        if (typeof item === 'bigint') return Str(item);
                        if (item !== null && typeof item === 'object') {
                            const kind = tag(item);
                            if (kind) {
                                const id = attribute(item, 'id');
                                const words = Str(item.textContent ?? '').replace(/\s+/g, ' ').trim().slice(0, 80);
                                return '<' + kind + (id ? '#' + id : '') + '>' + (words ? ' ' + words : '');
                            }
                            if (apply(wsHas, seen, [item])) return '[seen above]';
                            apply(wsAdd, seen, [item]);
                            if (typeof item.length === 'number' && typeof item.item === 'function') return Array.from(item);
                        }
                        return item;
                    }]);
                } catch (error) {
                    shown = Str(value);
                }
                if (shown === undefined) return null;
                return shown.length > most ? apply(slice, shown, [0, most]) + ' …(' + (shown.length - most) + ' more characters cut)' : shown;
            };
            guard = freeze({
                apply, construct, describe, define: defineProperty, text, lower, local, matches, tag, attribute, refuse, javascript,
                secret, isPasswordBox, pattern, method, setter, getter, install, reach,
                async run(code, most) {
                    const body = new AsyncFunction(code);
                    return show(await apply(body, undefined, []), most);
                },
            });
            return install;
        })();
        """#
    }

    /// Password and card values read as `••••` in this world: the value
    /// itself, a form's data, a selection in one, keys typed into one; and
    /// a password box's type can't be changed.
    static let passwords = #"""
        (win, guard) => {
            const { apply, describe, secret, isPasswordBox, refuse, tag } = guard;
            const masked = (element, value) => secret(element) && value !== '' ? '••••' : value;
            guard.getter(win.HTMLInputElement.prototype, 'value', masked);
            guard.getter(win.HTMLTextAreaElement.prototype, 'value', masked);
            guard.setter(win.HTMLInputElement.prototype, 'type', (element, value) => {
                if (isPasswordBox(element)) refuse("change a password box's type");
                return value;
            });

            // A form's data, made here or handed to a formdata listener.
            const OriginalFormData = win.FormData;
            const set = OriginalFormData.prototype.set;
            const elementsOf = describe(win.HTMLFormElement.prototype, 'elements').get;
            const lengthOf = describe(win.HTMLCollection.prototype, 'length').get;
            const itemOf = win.HTMLCollection.prototype.item;
            const masks = (data, form) => {
                if (!form || tag(form) !== 'form') return data;
                const elements = apply(elementsOf, form, []);
                const count = apply(lengthOf, elements, []);
                for (let i = 0; i < count; i++) {
                    const element = apply(itemOf, elements, [i]);
                    const name = guard.attribute(element, 'name');
                    if (name && secret(element)) apply(set, data, [name, '••••']);
                }
                return data;
            };
            const FormData = function FormData(form, submitter) {
                if (!new.target) throw new TypeError("Constructor FormData requires 'new'");
                return masks(guard.construct(OriginalFormData, arguments, new.target === FormData ? OriginalFormData : new.target), form);
            };
            FormData.prototype = OriginalFormData.prototype;
            guard.define(OriginalFormData.prototype, 'constructor', { value: FormData, writable: false, configurable: false });
            guard.define(win, 'FormData', { value: FormData, writable: false, configurable: false });
            const targetOf = describe(win.Event.prototype, 'target').get;
            const forEach = OriginalFormData.prototype.forEach, append = OriginalFormData.prototype.append;
            if (win.FormDataEvent && forEach) {
                guard.getter(win.FormDataEvent.prototype, 'formData', (event, data) => {
                    const copy = guard.construct(OriginalFormData, []);
                    apply(forEach, data, [(value, name) => apply(append, copy, [name, value])]);
                    return masks(copy, apply(targetOf, event, []));
                });
            }

            // Keys and text typed into a secret field, as events tell them.
            const inSecret = (event) => { try { return secret(apply(targetOf, event, [])); } catch { return false; } };
            const hide = (event, value) => !inSecret(event) ? value
                : typeof value === 'number' ? 0 : typeof value === 'string' && value !== '' ? '•' : value;
            const keys = ['key', 'code', 'keyCode', 'charCode', 'which'];
            for (let i = 0; i < keys.length; i++) guard.getter(win.KeyboardEvent.prototype, keys[i], hide);
            guard.getter(win.UIEvent.prototype, 'which', hide);
            guard.getter(win.InputEvent.prototype, 'data', hide);
            guard.getter(win.InputEvent.prototype, 'dataTransfer', (event, value) => inSecret(event) ? null : value);
            if (win.CompositionEvent) guard.getter(win.CompositionEvent.prototype, 'data', hide);
            if (win.TextEvent) guard.getter(win.TextEvent.prototype, 'data', hide);

            // Text selected in a secret field.
            const activeOf = describe(win.Document.prototype, 'activeElement').get;
            guard.method(win.Selection.prototype, 'toString', null, (selection, args, selected) => {
                const active = apply(activeOf, win.document, []);
                return active && secret(active) ? '' : selected;
            });
        }
        """#

    /// Ways of running code in the page's own world, where the guard isn't,
    /// refused: script elements, event handler attributes, javascript:
    /// addresses, HTML holding any of them, and a script element changed.
    /// Also a password box moved, or its form sent elsewhere.
    static let pageScript = #"""
        (win, guard) => {
            const { apply, describe, text, lower, local, matches, tag, refuse, isPasswordBox, javascript } = guard;
            const handler = guard.pattern(/^on/);
            const nodeTypeOf = describe(win.Node.prototype, 'nodeType').get;
            const connected = describe(win.Node.prototype, 'isConnected').get;
            const parentOf = describe(win.Node.prototype, 'parentNode').get;
            const attributesOf = describe(win.Element.prototype, 'attributes').get;
            const mapLength = describe(win.NamedNodeMap.prototype, 'length').get;
            const mapItem = win.NamedNodeMap.prototype.item;
            const mapNamed = win.NamedNodeMap.prototype.getNamedItem;
            const nameOf = describe(win.Attr.prototype, 'name').get;
            const valueOf = describe(win.Attr.prototype, 'value').get;
            const ownerOf = describe(win.Attr.prototype, 'ownerElement').get;
            const listLength = describe(win.NodeList.prototype, 'length').get;
            const listItem = win.NodeList.prototype.item;
            const selectAll = { 1: win.Element.prototype.querySelectorAll, 9: win.Document.prototype.querySelectorAll,
                                11: win.DocumentFragment.prototype.querySelectorAll };
            const contentOf = describe(win.HTMLTemplateElement.prototype, 'content').get;
            const createElement = win.Document.prototype.createElement;
            const setInnerHTML = describe(win.Element.prototype, 'innerHTML').set;
            const inert = win.document.implementation.createHTMLDocument('');
            const elementsOf = describe(win.HTMLFormElement.prototype, 'elements').get;
            const collectionLength = describe(win.HTMLCollection.prototype, 'length').get;
            const collectionItem = win.HTMLCollection.prototype.item;
            const formOfButton = describe(win.HTMLButtonElement.prototype, 'form').get;
            const formOfInput = describe(win.HTMLInputElement.prototype, 'form').get;

            const type = (node) => { try { return apply(nodeTypeOf, node, []); } catch { return 0; } };
            const each = (root, selector, check) => {
                const all = selectAll[type(root)];
                if (!all) return;
                const list = apply(all, root, [selector]);
                const count = apply(listLength, list, []);
                for (let i = 0; i < count; i++) check(apply(listItem, list, [i]));
            };

            // Where a form sends what is in it.
            const sending = { method: 1, action: 1, target: 1, enctype: 1, formmethod: 1, formaction: 1, formtarget: 1, formenctype: 1 };
            const formOf = (element) => {
                const kind = tag(element);
                if (kind === 'form') return element;
                if (kind === 'button') return apply(formOfButton, element, []);
                if (kind === 'input') return apply(formOfInput, element, []);
                return null;
            };
            const holdsPassword = (form) => {
                if (!form) return false;
                const elements = apply(elementsOf, form, []);
                const count = apply(collectionLength, elements, []);
                for (let i = 0; i < count; i++) if (isPasswordBox(apply(collectionItem, elements, [i]))) return true;
                return false;
            };

            /// HTML, parsed where nothing runs, refused if it holds script.
            const added = { script: 1, animate: 1, set: 1, animatemotion: 1, animatetransform: 1, base: 1, meta: 1 };
            const checkAdded = (element) => {
                const kind = tag(element);
                if (added[kind] === 1) refuse('add a <' + kind + '> element, which could run script in the page');
                const attributes = apply(attributesOf, element, []);
                const count = apply(mapLength, attributes, []);
                for (let i = 0; i < count; i++) {
                    const item = apply(mapItem, attributes, [i]);
                    const name = lower(apply(nameOf, item, []));
                    const value = apply(valueOf, item, []);
                    if (matches(handler, name)) refuse('add an event handler attribute, which would run in the page');
                    if (name === 'srcdoc') checkHTML(value);
                    if (matches(javascript, value)) refuse('add a javascript: address, which would run in the page');
                }
                if (kind === 'template') checkTree(apply(contentOf, element, []));
            };
            const checkTree = (root) => {
                if (type(root) === 1) checkAdded(root);
                each(root, '*', checkAdded);
            };
            const checkHTML = (html) => {
                const template = apply(createElement, inert, ['template']);
                apply(setInnerHTML, template, [text(html)]);
                checkTree(apply(contentOf, template, []));
            };

            /// An attribute about to be set on an element (or on none yet).
            const checkAttribute = (element, name, value) => {
                name = lower(name);
                if (tag(element) === 'script') refuse('change a script element');
                if ((name === 'type' || name === 'form') && isPasswordBox(element)) refuse('change a password box');
                if (matches(handler, name)) refuse('set an event handler attribute, which would run in the page');
                if (name === 'srcdoc') checkHTML(value);
                if (matches(javascript, value)) refuse('set a javascript: address, which would run in the page');
                if (sending[name] === 1 && holdsPassword(formOf(element))) refuse('change where a form with a password goes');
            };
            const checkRemoved = (element, name) => {
                name = lower(name);
                if (tag(element) === 'script') refuse('change a script element');
                if ((name === 'type' || name === 'form') && isPasswordBox(element)) refuse('change a password box');
                if (sending[name] === 1 && holdsPassword(formOf(element))) refuse('change where a form with a password goes');
            };
            const attributeNode = (node) => ({ name: apply(nameOf, node, []), value: apply(valueOf, node, []) });

            const Element = win.Element.prototype;
            guard.method(Element, 'setAttribute', (self, args) => {
                args[0] = text(args[0]); args[1] = text(args[1]);
                checkAttribute(self, args[0], args[1]);
            });
            guard.method(Element, 'setAttributeNS', (self, args) => {
                args[1] = text(args[1]); args[2] = text(args[2]);
                checkAttribute(self, local(args[1]), args[2]);
            });
            guard.method(Element, 'toggleAttribute', (self, args) => {
                args[0] = text(args[0]);
                checkAttribute(self, args[0], '');
                checkRemoved(self, args[0]);
            });
            guard.method(Element, 'removeAttribute', (self, args) => { args[0] = text(args[0]); checkRemoved(self, args[0]); });
            guard.method(Element, 'removeAttributeNS', (self, args) => { args[1] = text(args[1]); checkRemoved(self, local(args[1])); });
            const setNode = (self, args) => { const node = attributeNode(args[0]); checkAttribute(self, node.name, node.value); };
            guard.method(Element, 'setAttributeNode', setNode);
            guard.method(Element, 'setAttributeNodeNS', setNode);
            guard.method(Element, 'removeAttributeNode', (self, args) => checkRemoved(self, apply(nameOf, args[0], [])));
            const mapOwner = (map, name) => {
                const existing = apply(mapNamed, map, [name]) ?? (apply(mapLength, map, []) > 0 ? apply(mapItem, map, [0]) : null);
                return existing ? apply(ownerOf, existing, []) : null;
            };
            const setNamed = (self, args) => {
                const node = attributeNode(args[0]);
                checkAttribute(mapOwner(self, node.name), node.name, node.value);
            };
            const NamedNodeMap = win.NamedNodeMap.prototype;
            guard.method(NamedNodeMap, 'setNamedItem', setNamed);
            guard.method(NamedNodeMap, 'setNamedItemNS', setNamed);
            guard.method(NamedNodeMap, 'removeNamedItem', (self, args) => {
                args[0] = text(args[0]);
                checkRemoved(mapOwner(self, args[0]), args[0]);
            });
            guard.method(NamedNodeMap, 'removeNamedItemNS', (self, args) => {
                args[1] = text(args[1]);
                checkRemoved(mapOwner(self, args[1]), local(args[1]));
            });
            const attributeText = (node, value) => {
                if (value === null || value === undefined) value = '';
                value = text(value);
                const kind = type(node);
                if (kind === 2) checkAttribute(apply(ownerOf, node, []), apply(nameOf, node, []), value);
                if (kind === 1 && tag(node) === 'script') refuse('change a script element');
                return value;
            };
            guard.setter(win.Attr.prototype, 'value', attributeText);
            guard.setter(win.Node.prototype, 'nodeValue', attributeText);
            guard.setter(win.Node.prototype, 'textContent', attributeText);

            // Addresses that would run script in the page.
            const addresses = [[win.HTMLAnchorElement, 'href'], [win.HTMLAreaElement, 'href'], [win.HTMLIFrameElement, 'src'],
                [win.HTMLFrameElement, 'src'], [win.HTMLEmbedElement, 'src'], [win.HTMLObjectElement, 'data'],
                [win.HTMLFormElement, 'action'], [win.HTMLButtonElement, 'formAction'], [win.HTMLInputElement, 'formAction']];
            for (let i = 0; i < addresses.length; i++) {
                const kind = addresses[i][0], name = addresses[i][1];
                if (kind) guard.setter(kind.prototype, name, (element, value) => { value = text(value); checkAttribute(element, name, value); return value; });
            }
            const sendingProperties = [[win.HTMLFormElement, 'method'], [win.HTMLFormElement, 'target'], [win.HTMLFormElement, 'enctype'],
                [win.HTMLFormElement, 'encoding'], [win.HTMLButtonElement, 'formMethod'], [win.HTMLButtonElement, 'formTarget'],
                [win.HTMLButtonElement, 'formEnctype'], [win.HTMLInputElement, 'formMethod'], [win.HTMLInputElement, 'formTarget'],
                [win.HTMLInputElement, 'formEnctype']];
            for (let i = 0; i < sendingProperties.length; i++) {
                const kind = sendingProperties[i][0], name = sendingProperties[i][1];
                guard.setter(kind.prototype, name, (element, value) => { checkRemoved(element, 'method'); return value; });
            }
            // Sent as it is, without the page's own handlers: a form with a
            // password that isn't posted would put it in the address.
            const posts = guard.pattern(/^(post|dialog)$/);
            guard.method(win.HTMLFormElement.prototype, 'submit', (form) => {
                if (holdsPassword(form) && !matches(posts, lower(guard.attribute(form, 'method') ?? ''))) {
                    refuse('send a form with a password in its address; click its button, or call requestSubmit');
                }
            });
            guard.setter(win.HTMLIFrameElement.prototype, 'srcdoc', (element, value) => { value = text(value); checkHTML(value); return value; });
            const scriptProperties = ['src', 'text', 'type', 'textContent', 'innerText', 'innerHTML'];
            for (let i = 0; i < scriptProperties.length; i++) {
                guard.setter(win.HTMLScriptElement.prototype, scriptProperties[i], () => refuse('change a script element'));
            }
            const notScript = (element, value) => { if (tag(element) === 'script') refuse('change a script element'); return value; };
            guard.setter(win.HTMLElement.prototype, 'innerText', notScript);
            guard.setter(win.HTMLElement.prototype, 'outerText', notScript);

            // HTML put into the page.
            const html = (element, value) => { value = text(value); notScript(element, value); checkHTML(value); return value; };
            guard.setter(Element, 'innerHTML', html);
            guard.setter(Element, 'outerHTML', html);
            guard.setter(win.ShadowRoot.prototype, 'innerHTML', html);
            guard.method(Element, 'insertAdjacentHTML', (self, args) => { args[1] = text(args[1]); checkHTML(args[1]); });
            guard.method(Element, 'setHTMLUnsafe', (self, args) => { args[0] = html(self, args[0]); });
            guard.method(win.ShadowRoot.prototype, 'setHTMLUnsafe', (self, args) => { args[0] = text(args[0]); checkHTML(args[0]); });
            const written = (self, args) => {
                let all = '';
                for (let i = 0; i < args.length; i++) { args[i] = text(args[i]); all += args[i]; }
                checkHTML(all);
            };
            guard.method(win.Document.prototype, 'write', written);
            guard.method(win.Document.prototype, 'writeln', written);
            const parsed = (self, args, result) => { checkTree(result); return result; };
            guard.method(win.DOMParser.prototype, 'parseFromString', (self, args) => { args[0] = text(args[0]); }, parsed);
            guard.method(win.Range.prototype, 'createContextualFragment', (self, args) => { args[0] = text(args[0]); }, parsed);
            guard.method(win.Document, 'parseHTMLUnsafe', (self, args) => { args[0] = text(args[0]); }, parsed);

            // Script elements made or put in the page, and password boxes moved.
            guard.method(win.Document.prototype, 'createElement', (self, args) => {
                args[0] = text(args[0]);
                if (lower(args[0]) === 'script') refuse('make a script element, which would run in the page');
            });
            guard.method(win.Document.prototype, 'createElementNS', (self, args) => {
                args[1] = text(args[1]);
                if (local(args[1]) === 'script') refuse('make a script element, which would run in the page');
            });
            const checkInserted = (node) => {
                if (node === null || typeof node !== 'object') return;
                const kind = type(node);
                if (kind !== 1 && kind !== 11) return;
                const one = (element) => {
                    if (tag(element) === 'script') refuse('put a script element in the page');
                    if (isPasswordBox(element) && apply(connected, element, [])) refuse('move a password box');
                };
                if (kind === 1) one(node);
                each(node, 'script, input', one);
            };
            const into = (parent) => { if (tag(parent) === 'script') refuse('change a script element'); };
            const inserting = (self, args) => {
                into(self);
                for (let i = 0; i < args.length; i++) checkInserted(args[i]);
            };
            const besides = (self, args) => {
                into(apply(parentOf, self, []));
                for (let i = 0; i < args.length; i++) checkInserted(args[i]);
            };
            const reached = (self, args, result) => { guard.reach(win); return result; };
            const Node = win.Node.prototype;
            guard.method(Node, 'appendChild', inserting, reached);
            guard.method(Node, 'insertBefore', (self, args) => { into(self); checkInserted(args[0]); }, reached);
            guard.method(Node, 'replaceChild', (self, args) => { into(self); checkInserted(args[0]); }, reached);
            const lists = [win.Element.prototype, win.Document.prototype, win.DocumentFragment.prototype];
            const listMethods = ['append', 'prepend', 'replaceChildren'];
            for (let i = 0; i < lists.length; i++) {
                for (let j = 0; j < listMethods.length; j++) guard.method(lists[i], listMethods[j], inserting, reached);
            }
            const siblings = [win.Element.prototype, win.CharacterData.prototype, win.DocumentType.prototype];
            const siblingMethods = ['before', 'after', 'replaceWith'];
            for (let i = 0; i < siblings.length; i++) {
                for (let j = 0; j < siblingMethods.length; j++) guard.method(siblings[i], siblingMethods[j], besides, reached);
            }
            guard.method(Element, 'insertAdjacentElement', (self, args) => {
                into(self); into(apply(parentOf, self, []));
                checkInserted(args[1]);
            }, reached);
            guard.method(win.Range.prototype, 'insertNode', (self, args) => checkInserted(args[0]), reached);
            guard.method(win.Range.prototype, 'surroundContents', (self, args) => { into(args[0]); checkInserted(args[0]); }, reached);
        }
        """#

    /// Frames of the same site, and windows the agent opens or hears from:
    /// the guard is set up in each as the agent reaches it.
    static let frames = #"""
        (win, guard) => {
            const { apply, describe, install, reach, matches, javascript, refuse, text } = guard;
            const viewOf = describe(win.Document.prototype, 'defaultView').get;
            const windowFrom = (child) => { if (child) { install(child); reach(child); } return child; };
            const documentFrom = (document) => {
                if (document) { try { windowFrom(apply(viewOf, document, [])); } catch { } }
                return document;
            };
            const owners = [win.HTMLIFrameElement, win.HTMLFrameElement, win.HTMLObjectElement, win.HTMLEmbedElement];
            for (let i = 0; i < owners.length; i++) {
                if (!owners[i]) continue;
                const proto = owners[i].prototype;
                guard.getter(proto, 'contentWindow', (element, child) => windowFrom(child));
                guard.getter(proto, 'contentDocument', (element, document) => documentFrom(document));
                guard.method(proto, 'getSVGDocument', null, (element, args, document) => documentFrom(document));
            }
            const opens = describe(win, 'open') ? win : win.Window.prototype;
            guard.method(opens, 'open', (self, args) => {
                if (args.length > 0 && args[0] !== undefined) {
                    args[0] = text(args[0]);
                    if (matches(javascript, args[0])) refuse('open a javascript: address, which would run in the page');
                }
            }, (self, args, opened) => windowFrom(opened));
            guard.getter(describe(win, 'opener') ? win : win.Window.prototype, 'opener', (self, opener) => windowFrom(opener));
            guard.getter(win.MessageEvent.prototype, 'source', (event, source) => windowFrom(source));
        }
        """#
}
