import NaturalLanguage
import SwiftUI
@preconcurrency import Translation
import WebKit

/// A page in a language that isn't one of yours, translated as Safari does
/// it: on this Mac, by Apple's Translation framework, nothing sent anywhere.
/// The page's text is taken in Nerda's own script world a block at a time,
/// so a sentence split by links is translated whole, sent off nearest the
/// screen first, and each written back where it was as it comes; what the
/// page adds while translated is translated too. Show Original
/// puts back what was there. Each window has one of these, which translates
/// the tab on screen; a tab out of sight waits for it.
// ponytail: the top frame only; text inside a page's frames stays as it is.
final class Translator {
    /// The languages a tab's page is translated from and to.
    struct Pair: Equatable {
        let source: String
        let target: String
    }

    /// Strings and characters asked for at a time. Asking costs next to
    /// nothing, and the Mac translates some 60 characters a second, one string
    /// after another however many are sent, so a batch is small: what comes
    /// next is taken from where the page is scrolled to by then.
    static let batch = 10
    static let batchCharacters = 500

    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Nudged since the page was last asked: a page's word that it has more
    /// can come in before its answer that it had none.
    private var nudged = false

    /// Something may have changed: another tab on screen, a page in, text
    /// added to one being translated.
    func nudge() {
        nudged = true
        let woken = waiting
        waiting = []
        for continuation in woken { continuation.resume() }
    }

    private func idle() async {
        if nudged { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append($0) }
        } onCancel: {
            Task { @MainActor in self.nudge() }
        }
    }

    /// For as long as SwiftUI keeps `session` (the window's tab on screen
    /// translated, between the same two languages): ask its page for text,
    /// translate it, put it back, and wait when there is none. The first
    /// ask is where the framework offers to download the languages.
    func run(_ session: TranslationSession, in browser: Browser) async {
        guard let pair = browser.selected?.translation else { return }
        var busy: Tab?
        defer { busy?.translating = false }
        do {
            try await session.prepareTranslation()
        } catch {
            if let tab = browser.selected, tab.translation == pair { await failed(tab, pair, error, in: browser) }
            return
        }
        var translated = false
        while !Task.isCancelled {
            guard let tab = browser.selected, tab.translation == pair else { return }
            if busy !== tab {
                busy?.translating = false
                busy = tab
            }
            nudged = false
            guard let page = tab.page, let texts = await Self.next(on: page), !texts.isEmpty else {
                tab.translating = false
                await idle()
                continue
            }
            tab.translating = true
            do {
                // Each put in its place as it comes, so the first is on screen
                // before the rest are done.
                let requests = texts.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
                for try await response in session.translate(batch: requests) {
                    guard let id = response.clientIdentifier.flatMap(Int.init) else { continue }
                    _ = try? await page.callAsyncJavaScript("window.nerdaTranslate?.put(results)",
                                                            arguments: ["results": [["id": id, "text": response.targetText]]],
                                                            contentWorld: .defaultClient)
                    translated = true
                }
            } catch {
                if Task.isCancelled { return }
                // One batch the framework turned down is left as it was; a
                // first one says the languages can't be had.
                if !translated {
                    await failed(tab, pair, error, in: browser)
                    return
                }
            }
        }
    }

    /// Translation stopped before anything came back: the page is left as it
    /// is. Said why, unless the person turned down the languages' download.
    private func failed(_ tab: Tab, _ pair: Pair, _ error: any Error, in browser: Browser) async {
        if Task.isCancelled { return }
        tab.showOriginal()
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: pair.source),
                                                         to: Locale.Language(identifier: pair.target))
        if error is CancellationError || status == .supported { return }
        guard let window = browser.window else { return }
        let alert = NSAlert()
        if status == .unsupported {
            alert.messageText = "Translation isn't available"
            alert.informativeText = "Nerda can't translate \(Self.name(pair.source)) to \(Self.name(pair.target)) on this Mac."
        } else {
            alert.messageText = "This page couldn't be translated"
            alert.informativeText = error.localizedDescription
        }
        await alert.beginSheetModal(for: window)
    }

    /// The page's next batch, nearest the screen first; Nerda's script is put
    /// in the page the first time.
    private static func next(on page: WKWebView) async -> [(id: Int, text: String)]? {
        let next = "return window.nerdaTranslate?.next(\(batch), \(batchCharacters)) ?? false"
        var result = try? await page.callAsyncJavaScript(next, contentWorld: .defaultClient)
        if result as? Bool == false {
            result = try? await page.callAsyncJavaScript(script + next, contentWorld: .defaultClient)
        }
        guard let items = result as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let id = item["id"] as? Int, let text = item["text"] as? String else { return nil }
            return (id, text)
        }
    }

    /// The page's language, taken from it once it is in: what the page says it
    /// is in (`<html lang>`), or else what its first thousand characters are.
    /// Offered for translation only when it is none of yours.
    static func detect(on tab: Tab) async {
        guard let page = tab.page, let url = page.url, ["http", "https", "file"].contains(url.scheme) else { return }
        // A page come back from Back or Forward as it was left, translated,
        // where the tab no longer is.
        defer { if tab.page === page, tab.translation == nil { tab.restoreOriginal() } }
        let found = try? await page.callAsyncJavaScript(sample, contentWorld: .defaultClient) as? [String: String]
        var language = found?["lang"]
        if language == nil, let text = found?["text"], text.count > 40 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            language = recognizer.dominantLanguage?.rawValue
        }
        guard let source = foreign(language, to: PreferredLanguage.chosen) else { return }
        var targets: [String] = []
        for target in yours(PreferredLanguage.chosen) {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                             to: Locale.Language(identifier: target))
            if status != .unsupported { targets.append(target) }
        }
        // Gone on to another page meanwhile.
        guard tab.page === page, page.url == url else { return }
        tab.pageLanguage = source
        tab.translationTargets = targets
        (tab.delegate as? Browser)?.translator.nudge()
    }

    /// The page's language when it is none of `yours`, by language alone:
    /// English is English, British or American.
    static func foreign(_ language: String?, to yours: [String]) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespaces), let code = code(of: language),
              !["und", "mul", "zxx"].contains(code), Locale.LanguageCode(code).isISOLanguage,
              !yours.contains(where: { self.code(of: $0) == code }) else { return nil }
        return language
    }

    /// Your languages, each once: the first of English (US) and English (UK).
    static func yours(_ languages: [String]) -> [String] {
        var seen: Set<String> = []
        return languages.filter { code(of: $0).map { seen.insert($0).inserted } ?? false }
    }

    private static func code(of language: String) -> String? {
        Locale.Language(identifier: language).languageCode?.identifier.lowercased()
    }

    /// A language by its name alone, "English" for en-GB, as Safari's menu has it.
    static func name(_ language: String) -> String {
        code(of: language).flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? language
    }

    /// What the page says its language is, or failing that, some of its text.
    private static let sample = """
        const lang = document.documentElement.lang.trim();
        if (lang) return { lang };
        let text = '';
        const walker = document.createTreeWalker(document.body ?? document.documentElement, NodeFilter.SHOW_TEXT);
        while (text.length < 1000 && walker.nextNode()) {
            const parent = walker.currentNode.parentElement?.localName;
            if (parent === 'script' || parent === 'style' || parent === 'noscript') continue;
            const words = walker.currentNode.data.trim();
            if (words) text += words + ' ';
        }
        return { text };
        """

    /// Kept in the page (in Nerda's world, out of the page's sight) while it
    /// is translated. What goes to be translated is a sentence, not a text
    /// node: each run of a block's inline content (a paragraph, a list item, a
    /// cell, a caption, a button) as one string, with its links, bold and the
    /// like marked by number, `⟦1⟧…⟦/1⟧`, so that it is translated as a whole
    /// and each comes back round its own words, in the translation's order.
    /// Code, images and what a page marks `translate="no"` go as an empty mark
    /// and stay as they are; fields being typed in stay too. The title, alt and
    /// placeholder words go one each. `next` hands out those nearest the screen
    /// first, `put` writes the translations back, `restore` puts every node
    /// back as it was. What the page adds or changes meanwhile is taken too.
    /// A page gives at most `most` characters, so an endless feed doesn't keep
    /// the Mac busy.
    static let script = """
        window.nerdaTranslate ??= (() => {
            const most = 100000, mostStrings = 10000;
            const skipped = ['script', 'style', 'noscript', 'template', 'title', 'textarea', 'code', 'pre', 'kbd', 'samp',
                             'var', 'svg', 'math', 'canvas', 'iframe', 'object'];
            const skips = new Set(skipped);
            const outside = skipped.join(',') + ',.notranslate';
            // Inside a sentence, their words part of it.
            const inline = new Set(['a', 'abbr', 'b', 'bdi', 'bdo', 'big', 'cite', 'data', 'del', 'dfn', 'em', 'font', 'i',
                                    'ins', 'mark', 'q', 's', 'small', 'span', 'strong', 'sub', 'sup', 'time', 'tt', 'u']);
            const hidden = new Set(['script', 'style', 'noscript', 'template']);
            // Inside a sentence too, as they are.
            const phrasing = new Set([...inline, ...hidden, 'code', 'kbd', 'samp', 'var', 'svg', 'math', 'canvas', 'iframe',
                                      'object', 'img', 'picture', 'input', 'select', 'wbr', 'video', 'audio']);
            const words = ['title', 'alt', 'placeholder'];
            // A mark as it comes back: German's often ends `⟧/1⟧`.
            const letter = /\\p{L}/u, marks = /[⟦⟧]/g, mark = /⟦(\\d+)⟧|[⟦⟧]\\/(\\d+)⟧/g;
            let on = false, sent = 0, last = 0, told = false;
            let items = new Map(), known = new WeakMap(), pending = [];
            // Each text node Nerda wrote, with what it had (null for one Nerda
            // added), and each run it put in another order, as it was.
            let wrote = new Map(), moved = [];

            const read = item => item.node === document ? document.title : item.node.getAttribute(item.key);
            const write = (item, value) => {
                if (item.node === document) document.title = value;
                else item.node.setAttribute(item.key, value);
            };
            const kept = element => skips.has(element.localName) || element.translate === false || element.isContentEditable
                || element.classList.contains('notranslate');
            const excluded = element => !!element.closest(outside) || element.translate === false || element.isContentEditable;
            const marked = element => inline.has(element.localName) && !kept(element);
            // Part of the sentence round it, not a block of its own.
            const flat = element => phrasing.has(element.localName)
                && (!inline.has(element.localName) || kept(element) || [...element.children].every(flat));
            const blockOf = node => {
                let element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
                while (element && element !== document.body && flat(element)) element = element.parentElement;
                return element;
            };
            const worded = node => node.nodeType === Node.TEXT_NODE ? /\\S/.test(shown(node))
                : node.nodeType === Node.ELEMENT_NODE && marked(node) && letter.test(node.textContent);
            // A text node's words as the page has them, under Nerda's.
            const shown = node => {
                const record = wrote.get(node);
                return record?.written === node.data ? record.original ?? '' : node.data;
            };

            // New, or changed by the page: asked for again. A value Nerda wrote is its own.
            const add = (node, key, value, run) => {
                if (!value || !letter.test(value)) return;
                let keys = known.get(node);
                const item = items.get(keys?.get(key));
                if (item) {
                    item.run = run;
                    if (value === item.original || !run && value === item.translated) return;
                    item.original = value;
                    item.translated = undefined;
                    if (!pending.includes(item.id)) pending.push(item.id);
                    return;
                }
                if (items.size >= mostStrings) return;
                if (!keys) known.set(node, keys = new Map());
                const id = ++last;
                keys.set(key, id);
                items.set(id, { id, node, key, original: value, run });
                pending.push(id);
            };

            // A run as one string, each element in it numbered in order:
            // `⟦1⟧its words⟦/1⟧`, or `⟦2⟧⟦/2⟧` for one kept as it is, or
            // with no words (a note's number, an icon).
            const serialise = nodes => {
                const parts = [null], parents = [0], inner = [true];
                const walk = (nodes, parent) => nodes.map(node => {
                    if (node.nodeType === Node.TEXT_NODE) return shown(node).replace(marks, '');
                    if (node.nodeType !== Node.ELEMENT_NODE || hidden.has(node.localName)) return '';
                    const i = parts.push(node) - 1;
                    parents.push(parent);
                    inner.push(worded(node));
                    return `⟦${i}⟧${inner[i] ? walk([...node.childNodes], i) : ''}⟦/${i}⟧`;
                }).join('');
                const text = walk(nodes, 0).replace(/\\s+/g, ' ');
                return { nodes, parts, parents, inner, text: text.trim(), before: text.startsWith(' '), after: text.endsWith(' ') };
            };

            // A block's runs of inline content, between the blocks in it: a
            // paragraph is one, a list one per item.
            const refresh = block => {
                if (excluded(block)) return;
                let run = [], count = 0;
                const end = () => {
                    // Icons and spaces at either end stay as they are, and a
                    // link that is the whole run is translated inside.
                    for (;;) {
                        while (run.length && !worded(run[0])) run.shift();
                        while (run.length && !worded(run.at(-1))) run.pop();
                        if (run.length !== 1 || run[0].nodeType !== Node.ELEMENT_NODE) break;
                        run = [...run[0].childNodes];
                    }
                    const key = 'run' + count++;
                    if (run.length) {
                        const serialised = serialise(run);
                        add(block, key, serialised.text, serialised);
                    }
                    run = [];
                };
                for (const node of block.childNodes) {
                    if (node.nodeType !== Node.ELEMENT_NODE || flat(node)) run.push(node);
                    else end();
                }
                end();
            };

            const collect = root => {
                if (root.nodeType !== Node.ELEMENT_NODE || excluded(root)) return;
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
                    acceptNode: node => kept(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
                });
                for (let node = root; node; node = walker.nextNode()) {
                    for (const key of words) {
                        const value = node.getAttribute(key);
                        if (value) add(node, key, value);
                    }
                    if (!flat(node)) refresh(node);
                }
            };

            const handle = records => {
                const blocks = new Set();
                for (const record of records) {
                    const target = record.target;
                    if (target.localName === 'title' || target.parentElement?.localName === 'title') {
                        add(document, 'title', document.title);
                    } else if (record.type === 'attributes') {
                        if (!excluded(target)) add(target, record.attributeName, target.getAttribute(record.attributeName));
                    } else if (document.body?.contains(target)) {
                        for (const node of record.addedNodes) if (document.body.contains(node)) collect(node);
                        blocks.add(blockOf(target));
                    }
                }
                for (const block of blocks) if (block) refresh(block);
            };

            const changes = new MutationObserver(records => {
                handle(records);
                // Once until Nerda next asks: a page changing all the time is one nudge.
                if (pending.length && !told) {
                    told = true;
                    globalThis.webkit?.messageHandlers?.translate?.postMessage(null);
                }
            });

            const start = () => {
                on = true;
                add(document, 'title', document.title);
                if (document.body) collect(document.body);
                changes.observe(document.documentElement, {
                    childList: true, characterData: true, subtree: true, attributes: true, attributeFilter: words,
                });
            };

            // How far from the screen, in pixels: the title first, then what
            // is on screen, then what is further away, then what isn't shown.
            // A tip or an image's words wait for all the text.
            const distance = item => {
                if (item.node === document) return -1;
                if (item.key === 'title' || item.key === 'alt') return 1e8 + distance({ node: item.node });
                const first = item.run?.nodes[0];
                const element = !first ? item.node : first.nodeType === Node.ELEMENT_NODE ? first : first.parentElement;
                const box = element.getBoundingClientRect();
                if (!box.width && !box.height) return 1e9;
                if (box.bottom < 0) return -box.bottom;
                if (box.top > innerHeight) return box.top - innerHeight;
                // On screen, what the page is about before its menus.
                return element.closest('main, article, [role=main]') ? 0 : 1;
            };

            // The translation's text and elements by number, `tree[0]` the
            // run's own and `tree[i]` element i's; null unless each mark came
            // back once, nested as it went. An empty one left out goes after
            // the words round it.
            const parse = (text, run) => {
                const tree = [[]], open = [0];
                let at = 0;
                for (const found of text.matchAll(mark)) {
                    if (found.index > at) tree[open.at(-1)].push(text.slice(at, found.index));
                    at = found.index + found[0].length;
                    const i = +(found[1] ?? found[2]);
                    if (found[2]) {
                        if (open.length === 1 || open.at(-1) !== i) return null;
                        open.pop();
                    } else {
                        if (tree[i] || run.parents[i] !== open.at(-1)) return null;
                        tree[open.at(-1)].push(i);
                        tree[i] = [];
                        open.push(i);
                    }
                }
                if (text.length > at) tree[open.at(-1)].push(text.slice(at));
                if (open.length > 1) return null;
                for (let i = 1; i < run.parts.length; i++) {
                    if (tree[i]) continue;
                    if (run.inner[i] || !tree[run.parents[i]]) return null;
                    tree[run.parents[i]].push(i);
                    tree[i] = [];
                }
                return tree;
            };

            const setText = (node, value) => {
                const record = wrote.get(node);
                if (!record) wrote.set(node, { original: node.parentNode ? node.data : null, written: value });
                else {
                    if (record.written !== node.data) record.original = node.data;
                    record.written = value;
                }
                node.data = value;
            };

            // `segments` (text, and elements by number) in place of `kids` in
            // `parent`: the text in the text nodes there were, in order, and the
            // elements where the translation has them.
            const place = (parent, kids, segments, parts) => {
                const joined = [];
                for (const segment of segments) {
                    if (typeof segment === 'string' && typeof joined.at(-1) === 'string') joined[joined.length - 1] += segment;
                    else joined.push(segment);
                }
                const texts = kids.filter(node => node.nodeType === Node.TEXT_NODE);
                const anchor = kids.at(-1)?.nextSibling ?? null;
                let used = 0;
                const order = joined.map(segment => {
                    if (typeof segment === 'number') return parts[segment];
                    const node = texts[used++] ?? new Text();
                    setText(node, segment);
                    return node;
                });
                for (const node of texts.slice(used)) setText(node, '');
                const now = kids.filter(node => order.includes(node));
                if (order.length === now.length && order.every((node, i) => node === now[i])) return;
                moved.push({ parent, kids, anchor });
                for (const node of order) parent.insertBefore(node, anchor);
            };

            // The translation in the run's place: its words in the run's text
            // nodes, and each element round its own words, where the
            // translation has it. Marks that came back broken (none in 241 of
            // Wikipedia's French and German) leave the sentence whole and right
            // in the run's first text, its links emptied.
            const rebuild = (run, text) => {
                const tree = parse(text, run) ?? run.parts.map((_, i) => i ? [] : [text.replace(mark, '')]);
                if (run.before) tree[0].unshift(' ');
                if (run.after) tree[0].push(' ');
                place(run.nodes[0].parentNode, run.nodes, tree[0], run.parts);
                run.parts.forEach((part, i) => { if (i && run.inner[i]) place(part, [...part.childNodes], tree[i], run.parts); });
            };

            return {
                next(count, characters) {
                    if (!on) start();
                    told = false;
                    if (sent >= most) return [];
                    const order = pending.map(id => items.get(id))
                        .filter(item => item && (item.node === document || item.node.isConnected))
                        .map(item => [item, distance(item)])
                        .sort((a, b) => a[1] - b[1]);
                    const batch = [];
                    let size = 0;
                    for (const [item] of order) {
                        if (batch.length >= count || size >= characters) break;
                        const text = item.original.trim();
                        item.asked = item.original;
                        size += text.length;
                        batch.push({ id: item.id, text });
                    }
                    pending = order.slice(batch.length).map(([item]) => item.id);
                    sent += size;
                    return batch;
                },
                // Only over what is still there as it was sent: what the page
                // changed meanwhile is asked for again. The page's changes
                // before now are taken first, and Nerda's own are not changes.
                put(results) {
                    handle(changes.takeRecords());
                    for (const { id, text } of results) {
                        const item = items.get(id);
                        if (!item || item.asked !== item.original) continue;
                        if (item.run) {
                            if (item.run.nodes.every(node => node.isConnected)) rebuild(item.run, text);
                            continue;
                        }
                        if (read(item) !== item.original) continue;
                        const [, before, , after] = item.original.match(/^(\\s*)([\\s\\S]*?)(\\s*)$/);
                        item.translated = before + text + after;
                        write(item, item.translated);
                    }
                    changes.takeRecords();
                },
                restore() {
                    changes.disconnect();
                    for (const item of items.values()) {
                        if (!item.run && item.translated !== undefined && read(item) === item.translated) write(item, item.original);
                    }
                    for (const [node, { original, written }] of wrote) {
                        if (node.data !== written) continue;
                        if (original === null) node.remove();
                        else node.data = original;
                    }
                    for (const { parent, kids, anchor } of moved.reverse()) {
                        const at = anchor?.parentNode === parent ? anchor : null;
                        for (const node of kids) if (node.parentNode === parent) parent.insertBefore(node, at);
                    }
                    on = false;
                    sent = 0;
                    items = new Map();
                    known = new WeakMap();
                    pending = [];
                    wrote = new Map();
                    moved = [];
                },
            };
        })();

        """

    /// Text added to a page being translated, for the window to take up.
    static let messages = Messages()

    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let page = message.webView, let browser = page.uiDelegate as? Browser,
                  browser.selected?.page === page else { return }
            browser.translator.nudge()
        }
    }
}

extension Tab {
    /// What the tab is translating now: its page's language to the one
    /// chosen, while that page is in a language that isn't yours.
    var translation: Translator.Pair? {
        guard let pageLanguage, let translatedTo, translationTargets.contains(translatedTo) else { return nil }
        return .init(source: pageLanguage, target: translatedTo)
    }

    /// Translates the page, and from here on each page the tab opens that is
    /// in a language not yours, until Show Original.
    func translate(to language: String) {
        guard translatedTo != language else { return }
        if translatedTo != nil { restoreOriginal() }
        translatedTo = language
        (delegate as? Browser)?.translator.nudge()
    }

    func showOriginal() {
        translatedTo = nil
        translating = false
        restoreOriginal()
    }

    fileprivate func restoreOriginal() {
        page?.evaluateJavaScript("window.nerdaTranslate?.restore()", in: nil, in: .defaultClient)
    }
}

/// In the address bar, as Safari's, on a page in a language that isn't one of
/// yours: translates it into one that is, and back. Lit while the page is
/// translated, and pulsing while its text is on the way.
struct TranslateButton: View {
    let tab: Tab
    let openLanguages: () -> Void

    @State private var hovering = false

    var body: some View {
        let on = tab.translation != nil
        let source = tab.pageLanguage.map(Translator.name) ?? ""
        Menu {
            if tab.translationTargets.isEmpty {
                Text("\(source) can't be translated on this Mac")
            } else {
                ForEach(tab.translationTargets, id: \.self) { language in
                    Toggle("Translate to \(Translator.name(language))", isOn: Binding(
                        get: { on && tab.translatedTo == language },
                        set: { _ in tab.translate(to: language) }
                    ))
                }
                Button("Show Original", action: tab.showOriginal)
                    .disabled(!on)
            }
            Divider()
            Button("Preferred Languages…", action: openLanguages)
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                .symbolEffect(.pulse, isActive: tab.translating)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.wash : hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Translate")
        .accessibilityLabel("Translate")
        .accessibilityValue(on ? "Translated from \(source)" : "\(source), not translated")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}
