import Foundation

/// The page model's script: what agents read of a page, built in the page
/// model's own isolated world (`AgentPage.world`), once per frame, on the
/// first call into that frame. Nothing the page runs can see or change it.
///
/// It keeps the refs: each element shown to an agent gets one (e1, e2… and
/// in a frame from another site the frame's prefix, f1e1), from a counter
/// that only goes up, held weakly so the page's own elements are never kept
/// alive by it. A ref names its element for as long as the element is in the
/// document; once it is gone, one strict re-bind is tried (exactly one
/// element of the same kind and name in the document), and otherwise the ref
/// is stale.
///
/// Called as an async function body (`AgentPage.call`) with `op`, `args`
/// and `prefix` (for a frame read on its own: the prefix its refs get, given
/// once). Every op answers a JSON string:
/// - `outline` `{full, ref, providers, floor}`: `{lines, hidden, needs,
///   signs, count}`, refs numbered on from `floor` (the tab's highest yet,
///   so a ref from a page the tab has left never names an element on this one),
///   `lines` being `{d, t}` (depth, line text without the dash) or
///   `{d, frame}` where a frame from another site is to be read on its own
///   (`frame`: the path of indexes from this frame down, as in `window.frames`).
/// - `text` `{}`: `{parts, hidden}`, `parts` being strings and `{frame}`.
/// - `prefix`: the frame's prefix, or null before it has one.
/// - `{stale: ref}` instead of an answer when a ref is stale.
///
/// Later verbs reach an element through `AgentPage.run(_:on:)`, which binds
/// `element` with `nerdaAgent.element(ref)` before their own code runs.
nonisolated enum AgentPageScript {
    static let source = #"""
        if (!globalThis.nerdaAgent) globalThis.nerdaAgent = (() => {
            const agent = { prefix: null, count: 0 };
            /// ref → {element: WeakRef, role, name, rebound}; element → ref.
            const refs = new Map();
            const known = new WeakMap();
            /// Elements seen as password boxes: one a page turns into a
            /// text box to show it stays masked.
            const wasPassword = new WeakSet();

            const skipped = new Set(['script', 'style', 'template', 'noscript', 'head', 'meta', 'link', 'title']);
            const interactive = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox',
                'listbox', 'option', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
                'menuitemradio', 'treeitem', 'clickable', 'file']);
            /// Shown with the interactive ones, for where they are.
            const context = new Set(['heading', 'dialog', 'alertdialog', 'form', 'iframe', 'alert']);
            /// Shown in the full outline too.
            const structure = new Set(['img', 'list', 'listitem', 'navigation', 'main', 'banner', 'contentinfo',
                'complementary', 'region', 'table', 'row', 'cell', 'columnheader', 'rowheader', 'group', 'article',
                'figure', 'menu', 'menubar', 'tablist', 'tabpanel', 'tree', 'grid', 'gridcell', 'status', 'search',
                'video', 'audio', 'toolbar', 'radiogroup', 'progressbar', 'meter']);
            /// Their name is their content: nothing more is read inside them.
            const leaves = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'slider',
                'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'img',
                'heading', 'file', 'combobox', 'progressbar', 'meter']);
            const textBoxes = new Set(['', 'text', 'email', 'tel', 'url', 'password', 'number', 'search', 'date',
                'datetime-local', 'month', 'week', 'time', 'color']);

            const collapse = (text) => (text || '').replace(/\s+/g, ' ').trim();
            const cut = (text, most) => text.length > most ? text.slice(0, most - 1) + '…' : text;
            const quoted = (text) => JSON.stringify(text);
            const styleOf = (element) => element.ownerDocument.defaultView.getComputedStyle(element);

            /// Whether a person can see the element: not hidden by style,
            /// not shrunk to nothing, not moved off the page, not see-through.
            const shown = (element, style) => {
                if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
                if (style.contentVisibility === 'hidden') return false;
                if (parseFloat(style.opacity) === 0) return false;
                if (style.display === 'contents') return true;
                const box = element.getBoundingClientRect();
                const clipped = style.overflow === 'hidden' || style.overflowX === 'hidden' || style.clip.startsWith('rect(0');
                if (clipped && box.width <= 1 && box.height <= 1) return false;
                if (/inset\((50|100)%/.test(style.clipPath)) return false;
                if (style.position === 'absolute' || style.position === 'fixed') {
                    const view = element.ownerDocument.defaultView;
                    if (box.right + view.scrollX <= 0 || box.bottom + view.scrollY <= 0) return false;
                }
                if (parseFloat(style.fontSize) < 1 && !element.children.length) return false;
                return true;
            };

            /// The nodes inside a node as a person sees them: an open shadow
            /// root in place of what it hides, a slot's assigned nodes.
            const inside = (node) => {
                if (node.shadowRoot) return [...node.shadowRoot.childNodes];
                if (node.localName === 'slot') {
                    const assigned = node.assignedNodes({ flatten: true });
                    if (assigned.length) return assigned;
                }
                return [...node.childNodes];
            };

            const roleOf = (element) => {
                const given = (element.getAttribute('role') || '').trim().split(/\s+/)[0];
                if (given && given !== 'presentation' && given !== 'none') return given;
                const tag = element.localName;
                switch (tag) {
                case 'a': case 'area': return element.hasAttribute('href') ? 'link' : null;
                case 'button': case 'summary': return 'button';
                case 'input': {
                    const type = (element.getAttribute('type') || '').toLowerCase();
                    if (type === 'hidden') return null;
                    if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
                    if (type === 'checkbox') return element.getAttribute('switch') !== null ? 'switch' : 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'range') return 'slider';
                    if (type === 'number') return 'spinbutton';
                    if (type === 'search') return 'searchbox';
                    if (type === 'file') return 'file';
                    return 'textbox';
                }
                case 'select': return element.multiple || element.size > 1 ? 'listbox' : 'combobox';
                case 'textarea': return 'textbox';
                case 'option': return 'option';
                case 'img': return element.getAttribute('alt') === '' ? null : 'img';
                case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
                case 'nav': return 'navigation';
                case 'main': return 'main';
                case 'header': return element.closest('article, aside, main, nav, section') ? null : 'banner';
                case 'footer': return element.closest('article, aside, main, nav, section') ? null : 'contentinfo';
                case 'aside': return 'complementary';
                case 'section': return element.hasAttribute('aria-label') || element.hasAttribute('aria-labelledby') ? 'region' : null;
                case 'form': return 'form';
                case 'dialog': return 'dialog';
                case 'table': return 'table';
                case 'tr': return 'row';
                case 'td': return 'cell';
                case 'th': return 'columnheader';
                case 'ul': case 'ol': return 'list';
                case 'li': return 'listitem';
                case 'iframe': case 'frame': return 'iframe';
                case 'fieldset': return 'group';
                case 'article': return 'article';
                case 'figure': return 'figure';
                case 'video': return 'video';
                case 'audio': return 'audio';
                case 'progress': return 'progressbar';
                case 'meter': return 'meter';
                }
                if (element.isContentEditable && !element.parentElement?.isContentEditable) return 'textbox';
                return null;
            };

            /// An element that takes a click with nothing saying so: a
            /// pointer cursor its parent doesn't have, a tab stop, onclick.
            const clickable = (element, style) => {
                if (element.hasAttribute('onclick')) return true;
                const tabIndex = element.getAttribute('tabindex');
                if (tabIndex !== null && Number(tabIndex) >= 0) return true;
                if (style.cursor !== 'pointer' || !element.parentElement) return false;
                return styleOf(element.parentElement).cursor !== 'pointer';
            };

            /// The text inside a node, as a name: controls' own values left out.
            const textOf = (node, most = 200) => {
                let text = '';
                const walk = (node) => {
                    for (const child of inside(node)) {
                        if (text.length > most) return;
                        if (child.nodeType === Node.TEXT_NODE) text += ' ' + child.data;
                        else if (child.nodeType === Node.ELEMENT_NODE) {
                            const tag = child.localName;
                            if (skipped.has(tag) || ['input', 'select', 'textarea'].includes(tag)) continue;
                            if (tag === 'img' && child.alt) text += ' ' + child.alt;
                            else if (tag === 'svg') text += ' ' + (child.querySelector('title')?.textContent || '');
                            else walk(child);
                        }
                    }
                };
                walk(node);
                return collapse(text);
            };

            const byIDs = (element, ids) => ids.split(/\s+/)
                .map((id) => element.getRootNode().getElementById?.(id) || element.ownerDocument.getElementById(id))
                .filter(Boolean).map((labelling) => textOf(labelling)).join(' ');

            const nameOf = (element, role) => {
                const labelledBy = element.getAttribute('aria-labelledby');
                const named = labelledBy && collapse(byIDs(element, labelledBy));
                if (named) return named;
                const label = collapse(element.getAttribute('aria-label'));
                if (label) return label;
                const tag = element.localName;
                if (tag === 'input' || tag === 'select' || tag === 'textarea') {
                    const type = (element.getAttribute('type') || '').toLowerCase();
                    if (['button', 'submit', 'reset'].includes(type)) return collapse(element.value) || (type === 'reset' ? 'Reset' : 'Submit');
                    if (type === 'image') return collapse(element.alt) || 'Submit';
                    const labels = [...(element.labels || [])].map((label) => textOf(label)).join(' ');
                    if (collapse(labels)) return collapse(labels);
                    return collapse(element.getAttribute('placeholder')) || collapse(element.title) || '';
                }
                if (tag === 'img') return collapse(element.alt) || collapse(element.title);
                if (tag === 'iframe' || tag === 'frame') return collapse(element.title) || collapse(element.name);
                if (['form', 'dialog', 'navigation', 'main', 'region', 'group', 'list', 'table', 'article'].includes(role)) {
                    const legend = tag === 'fieldset' ? element.querySelector('legend') : null;
                    return legend ? textOf(legend) : collapse(element.title);
                }
                // What is typed in a box is its value, never its name.
                if (['textbox', 'searchbox', 'combobox', 'listbox', 'slider', 'spinbutton'].includes(role)) {
                    return collapse(element.getAttribute('aria-placeholder')) || collapse(element.title);
                }
                const text = textOf(element);
                return text || collapse(element.title);
            };

            /// Fields whose values never leave the page: passwords, cards,
            /// seed phrases, keys.
            const secretWords = /pass(word|code|phrase)?|card.?(number|num|no)|cc.?(num|number)|credit.?card|\bcvc|cvv|cvn|\bcsc\b|security.?code|card.?code|seed|mnemonic|recovery.?(phrase|key|words)|private.?key|secret|api.?key|access.?key|token|\biban\b/i;
            const secret = (element, name) => {
                const tag = element.localName;
                if (tag !== 'input' && tag !== 'textarea' && !element.isContentEditable) return false;
                const type = (element.getAttribute('type') || '').toLowerCase();
                if (type === 'password') { wasPassword.add(element); return true; }
                if (wasPassword.has(element)) return true;
                const complete = (element.getAttribute('autocomplete') || '').toLowerCase();
                if (/\bcc-(number|csc|exp|exp-month|exp-year)\b|current-password|new-password/.test(complete)) return true;
                const words = [element.name, element.id, element.getAttribute('aria-label'), element.getAttribute('placeholder'),
                    element.getAttribute('data-testid'), name].filter(Boolean).join(' ');
                if (secretWords.test(words)) return true;
                const digits = (element.value || '').replace(/[\s-]/g, '');
                return /^\d{13,19}$/.test(digits) && luhn(digits);
            };
            const luhn = (digits) => {
                let sum = 0;
                for (let i = 0; i < digits.length; i++) {
                    let digit = Number(digits[digits.length - 1 - i]);
                    if (i % 2) { digit *= 2; if (digit > 9) digit -= 9; }
                    sum += digit;
                }
                return sum % 10 === 0;
            };

            const valueOf = (element, role, name) => {
                const tag = element.localName;
                if (role === 'checkbox' || role === 'radio' || role === 'switch') return null;
                if (tag === 'select') return [...element.selectedOptions].map((option) => collapse(option.text)).join(', ');
                if (role === 'file') return [...(element.files || [])].map((file) => file.name).join(', ');
                let value = null;
                if (tag === 'input' || tag === 'textarea') {
                    const type = (element.getAttribute('type') || '').toLowerCase();
                    if (['button', 'submit', 'reset', 'image'].includes(type)) return null;
                    value = element.value;
                } else if (element.isContentEditable && role === 'textbox') value = element.innerText;
                else if (role === 'slider' || role === 'spinbutton' || role === 'progressbar' || role === 'meter') {
                    value = element.getAttribute('aria-valuetext') || element.getAttribute('aria-valuenow') || element.value;
                }
                if (value === null || value === undefined) return null;
                if (secret(element, name)) return value === '' ? '' : '••••';
                return cut(collapse(String(value)), 200);
            };

            const stateOf = (element, role) => {
                const states = [];
                const aria = (name) => element.getAttribute('aria-' + name);
                if (role === 'heading') states.push('level ' + (Number(element.localName.slice(1)) || Number(aria('level')) || 2));
                const checked = element.localName === 'input' ? (element.indeterminate ? 'mixed' : element.checked) : aria('checked');
                if (checked === true || checked === 'true') states.push('checked');
                if (checked === 'mixed') states.push('mixed');
                if (element.disabled || aria('disabled') === 'true') states.push('disabled');
                if (aria('expanded') === 'true') states.push('expanded');
                if (aria('expanded') === 'false') states.push('collapsed');
                if (element.localName === 'option' ? element.selected : aria('selected') === 'true') states.push('selected');
                if (aria('pressed') === 'true') states.push('pressed');
                if (element.required || aria('required') === 'true') states.push('required');
                if (element.readOnly && element.localName !== 'select' || aria('readonly') === 'true') states.push('read-only');
                if (aria('invalid') === 'true') states.push('invalid');
                if (element.ownerDocument.activeElement === element) states.push('focused');
                if (role === 'link') {
                    const href = element.getAttribute('href') || '';
                    if (href && !href.startsWith('javascript:')) states.push('to ' + cut(href, 120));
                }
                return states;
            };

            /// Refs handed out during the outline being made, and how many
            /// elements of each kind and name it has.
            let fresh = [];
            const alike = new Map();
            const keyOf = (role, name) => role + '\u0000' + name;

            const refOf = (element, role, name) => {
                let ref = known.get(element);
                const key = keyOf(role, name);
                alike.set(key, (alike.get(key) || 0) + 1);
                if (!ref) {
                    agent.count += 1;
                    ref = (agent.prefix || '') + 'e' + agent.count;
                    known.set(element, ref);
                    fresh.push({ element, ref, key });
                }
                const entry = refs.get(ref);
                if (entry && entry.element.deref() === element) { entry.role = role; entry.name = name; }
                else refs.set(ref, { element: new WeakRef(element), role, name, rebound: false });
                return ref;
            };

            /// An element drawn again (as React does) takes back the ref of
            /// the one it replaced, once: when it is the only one of its kind
            /// and name on the page, and the gone one was the only one too.
            const rebind = (lines) => {
                const gone = new Map();
                for (const [ref, entry] of refs) {
                    const element = entry.element.deref();
                    if (element && element.isConnected) continue;
                    if (entry.rebound) { refs.delete(ref); continue; }
                    const key = keyOf(entry.role, entry.name);
                    gone.set(key, gone.has(key) ? null : ref);
                }
                for (const { element, ref, key } of fresh) {
                    const old = gone.get(key);
                    if (!old || alike.get(key) !== 1) continue;
                    gone.delete(key);
                    const entry = refs.get(old);
                    entry.element = new WeakRef(element);
                    entry.rebound = true;
                    known.set(element, old);
                    refs.delete(ref);
                    const line = lines.find((line) => line.t?.startsWith(ref + ' '));
                    if (line) line.t = old + line.t.slice(ref.length);
                }
            };

            /// Every element of the document, through open shadow roots and
            /// frames of the same site.
            const everyElement = (root, visit) => {
                for (const child of inside(root)) {
                    if (child.nodeType !== Node.ELEMENT_NODE) continue;
                    visit(child);
                    const tag = child.localName;
                    if ((tag === 'iframe' || tag === 'frame') && child.contentDocument?.body) everyElement(child.contentDocument.body, visit);
                    everyElement(child, visit);
                }
            };

            /// The element a ref names, re-bound once if it is gone and
            /// exactly one element of the same kind and name took its place.
            agent.element = (ref) => {
                const entry = refs.get(ref);
                if (!entry) return null;
                const element = entry.element.deref();
                if (element && element.isConnected) return element;
                if (entry.rebound) return null;
                entry.rebound = true;
                const alike = [];
                everyElement(document.documentElement, (candidate) => {
                    if (alike.length > 1 || roleOf(candidate) !== entry.role) return;
                    if (nameOf(candidate, entry.role) === entry.name) alike.push(candidate);
                });
                if (alike.length !== 1) return null;
                entry.element = new WeakRef(alike[0]);
                if (!known.has(alike[0])) known.set(alike[0], ref);
                return alike[0];
            };

            /// Where a window is from this frame: its index in each parent's
            /// `frames`, down from here.
            const framePath = (view) => {
                const path = [];
                while (view && view !== window) {
                    const parent = view.parent;
                    let index = -1;
                    for (let i = 0; i < parent.frames.length; i++) if (parent.frames[i] === view) { index = i; break; }
                    if (index < 0 || parent === view) return null;
                    path.unshift(index);
                    view = parent;
                }
                return path;
            };

            /// A frame's document, when it is of this frame's site; null for
            /// one from another site, read on its own.
            const frameDocument = (frame) => {
                try { return frame.contentDocument; } catch { return null; }
            };

            const newReading = () => ({ hidden: { passages: 0, characters: 0 }, needs: new Set(), signs: [] });

            const countHidden = (reading, element) => {
                const text = collapse(element.textContent);
                if (!text) return;
                reading.hidden.passages += 1;
                reading.hidden.characters += text.length;
            };

            const codeWords = /one.?time|\botp\b|verification.?code|verify.?code|2fa|two.?factor|authenticat(ion|or).?code|security.?code|sms.?code|passcode|confirmation.?code/i;
            const captchaWords = /recaptcha|hcaptcha|turnstile|challenges\.cloudflare\.com|arkoselabs|funcaptcha|captcha/i;

            /// What the page asks for, from one element as it is passed.
            const notice = (reading, element, role, name) => {
                const tag = element.localName;
                if (tag === 'input') {
                    const type = (element.getAttribute('type') || '').toLowerCase();
                    if (type === 'password' || wasPassword.has(element)) reading.needs.add('password');
                    const complete = (element.getAttribute('autocomplete') || '').toLowerCase();
                    const words = [element.name, element.id, element.getAttribute('placeholder'), name].filter(Boolean).join(' ');
                    if (complete === 'one-time-code' || (role === 'textbox' || role === 'spinbutton') && codeWords.test(words) && !/card|cc-/i.test(words + complete)) {
                        reading.needs.add('one-time code');
                    }
                }
                if ((tag === 'iframe' && captchaWords.test(element.src || ''))
                    || element.hasAttribute('data-sitekey') && element.getAttribute('data-size') !== 'invisible'
                    || /\b(g-recaptcha|h-captcha|cf-turnstile)\b/.test(element.className?.baseVal ?? element.className ?? '')) {
                    reading.needs.add('captcha');
                }
            };

            const signWords = /sign|log|continue|connect|with|via|using|join|register/i;
            const signIn = (reading, providers, element, role, name, ref) => {
                if (!['button', 'link', 'clickable'].includes(role) || !name || name.length > 60) return;
                for (const provider of providers || []) {
                    const named = new RegExp(`(^|\\W)${provider}(\\W|$)`, 'i');
                    if (!named.test(name) || !(signWords.test(name) || collapse(name).toLowerCase() === provider.toLowerCase())) continue;
                    if (!reading.signs.some((sign) => sign.provider === provider)) reading.signs.push({ provider, ref });
                }
            };

            /// The outline under `root`: one line for each element shown,
            /// indented by depth.
            const outline = (root, full, providers) => {
                fresh = [];
                alike.clear();
                const reading = newReading();
                const lines = [];
                let text = '';
                const flush = (depth) => {
                    const line = collapse(text);
                    text = '';
                    if (line) lines.push({ d: depth, t: 'text ' + quoted(cut(line, 1000)) });
                };
                const walk = (node, depth) => {
                    for (const child of inside(node)) {
                        if (child.nodeType === Node.TEXT_NODE) {
                            if (full) text += ' ' + child.data;
                            continue;
                        }
                        if (child.nodeType !== Node.ELEMENT_NODE) continue;
                        visit(child, depth);
                    }
                };
                const visit = (element, depth) => {
                    const tag = element.localName;
                    if (skipped.has(tag)) return;
                    const style = styleOf(element);
                    if (!shown(element, style)) return countHidden(reading, element);
                    let role = roleOf(element);
                    if (!role && clickable(element, style)) role = 'clickable';
                    const name = role ? nameOf(element, role) : '';
                    notice(reading, element, role, name);
                    const listed = role && (interactive.has(role) || context.has(role) || full && structure.has(role));
                    const block = !style.display.startsWith('inline') && style.display !== 'contents';
                    if (full && (block || listed)) flush(depth);
                    if (!listed) {
                        if (tag === 'br' && full) text += '\n';
                        walk(element, depth);
                        if (full && block) flush(depth);
                        return;
                    }
                    if (role === 'alert' && !name) return;
                    const ref = refOf(element, role, name);
                    signIn(reading, providers, element, role, name, ref);
                    const value = valueOf(element, role, name);
                    const states = stateOf(element, role);
                    let line = `${ref} ${role}`;
                    if (name) line += ' ' + quoted(cut(name, 100));
                    if (value !== null && value !== '') line += ' = ' + quoted(value);
                    if (states.length) line += ' (' + states.join(', ') + ')';
                    lines.push({ d: depth, t: line });
                    if (role === 'iframe') {
                        const inner = frameDocument(element);
                        if (inner?.body) walk(inner.body, depth + 1);
                        else if (element.contentWindow) {
                            const path = framePath(element.contentWindow);
                            if (path) lines.push({ d: depth + 1, frame: path });
                        }
                        return;
                    }
                    if (tag === 'select') {
                        const options = [...element.options];
                        const most = full ? options.length : 25;
                        for (const option of options.slice(0, most)) {
                            const optionName = collapse(option.label || option.text);
                            const optionStates = option.selected ? ' (selected)' : '';
                            lines.push({ d: depth + 1, t: `${refOf(option, 'option', optionName)} option ${quoted(cut(optionName, 100))}${optionStates}` });
                        }
                        if (options.length > most) lines.push({ d: depth + 1, t: `text "${options.length - most} more options: the full snapshot lists them"` });
                        return;
                    }
                    if (!leaves.has(role)) walk(element, depth + 1);
                    if (full) flush(depth + 1);
                };
                if (root === document.documentElement) walk(document.body || root, 0);
                else visit(root, 0);
                flush(0);
                if (root === document.documentElement) rebind(lines);
                return { lines, reading };
            };

            /// The page's text as a person reads it: what is hidden left out.
            const text = () => {
                const reading = newReading();
                const parts = [];
                let current = '';
                const push = (piece) => { current += piece; };
                const walk = (node) => {
                    for (const child of inside(node)) {
                        if (child.nodeType === Node.TEXT_NODE) { push(child.data.replace(/\s+/g, ' ')); continue; }
                        if (child.nodeType !== Node.ELEMENT_NODE) continue;
                        const tag = child.localName;
                        if (skipped.has(tag) || ['input', 'select', 'textarea', 'option'].includes(tag)) continue;
                        if (tag === 'br') { push('\n'); continue; }
                        const style = styleOf(child);
                        if (!shown(child, style)) { countHidden(reading, child); continue; }
                        if (child.isContentEditable && !child.parentElement?.isContentEditable && secret(child, nameOf(child, 'textbox'))) {
                            push(' •••• ');
                            continue;
                        }
                        if (tag === 'img' && child.alt) push(' ' + child.alt + ' ');
                        const block = !style.display.startsWith('inline') && style.display !== 'contents';
                        const cell = style.display === 'table-cell';
                        if (block && !cell) push('\n');
                        if (tag === 'iframe' || tag === 'frame') {
                            const inner = frameDocument(child);
                            if (inner?.body) walk(inner.body);
                            else if (child.contentWindow) {
                                const path = framePath(child.contentWindow);
                                if (path) { parts.push(current); current = ''; parts.push({ frame: path }); }
                            }
                        } else walk(child);
                        if (cell) push('\t');
                        else if (block) push('\n');
                    }
                };
                walk(document.body || document.documentElement);
                parts.push(current);
                const tidy = (piece) => typeof piece === 'string'
                    ? piece.split('\n').map((line) => line.replace(/[ \t]+/g, ' ').trim()).join('\n').replace(/\n{3,}/g, '\n\n')
                    : piece;
                return { parts: parts.map(tidy), hidden: reading.hidden };
            };

            /// What the outline would call an element, for answers that
            /// name one outside an outline (the buttons of an overlay in
            /// the way): its ref if it has one already (refs are handed out
            /// by outlines only), its role and name, and the start of its text.
            agent.describe = (element) => {
                const style = styleOf(element);
                const role = roleOf(element) || (clickable(element, style) ? 'clickable' : null);
                return { ref: known.get(element) || null, role, name: role ? nameOf(element, role) : '',
                    text: cut(textOf(element, 120), 80), shown: shown(element, style) };
            };

            agent.outline = ({ full, ref, providers, floor }) => {
                agent.count = Math.max(agent.count, floor || 0);
                let root = document.documentElement;
                if (ref) {
                    root = agent.element(ref);
                    if (!root) return { stale: ref };
                }
                const { lines, reading } = outline(root, !!full || !!ref, providers);
                return { lines, hidden: reading.hidden, needs: [...reading.needs], signs: reading.signs, count: agent.count };
            };
            agent.text = () => text();
            return agent;
        })();

        const agent = globalThis.nerdaAgent;
        if (prefix && agent.prefix === null) agent.prefix = prefix;
        switch (op) {
        case 'prefix': return JSON.stringify(agent.prefix);
        case 'outline': return JSON.stringify(agent.outline(args));
        case 'text': return JSON.stringify(agent.text());
        }
        """#
}
