import WebKit

/// Find on Page's side in the page, as Safari and Chrome have it: every match
/// lit, the one on show brighter, selected and scrolled to the middle, and a
/// count of them. WebKit's own find counts nothing and knows no whole words,
/// so the page's text is read in Nerda's own world (`.defaultClient`), which
/// the page can't see into: not the query, not the list of matches. It can see
/// the matches lit, as CSS Custom Highlights (as `Selection` draws), and the
/// one selected.
///
/// Reading a long page costs, so its text is read once and kept until the
/// page changes, and the walk stops after `budget` elements (as Search's
/// does), with the count then shown as more than it found. A change is only
/// noted as it happens; the count catches up at the next look.
// ponytail: text in fields, in components (shadow DOM) and in other sites'
// frames isn't looked in.
enum Find {
    /// Where the look got to: the match on show, from 1, of `count`; `more`
    /// when it stopped short of the page's end.
    struct Matches: Equatable {
        let index: Int
        let count: Int
        let more: Bool
    }

    /// Safari stops counting at the same number.
    static let limit = 1000
    static let budget = 60_000

    static func install(in controller: WKUserContentController) {
        // ponytail: should the SPI go, matches are only selected, not lit.
        controller.addUserStyleSheet(css)
    }

    /// The colours: every match pale yellow, the one on show Safari's yellow,
    /// over WebKit's selection (`Selection`), which it also is.
    private static let css = """
        ::highlight(nerda-find) { background-color: rgb(255 214 10 / .35); }
        ::highlight(nerda-find-current) { background-color: rgb(255 214 10); color: black; }
        """

    /// `query` looked for on `page`, `step` matches on from the one on show
    /// (a new query starts at the first, or the last going back); nil where
    /// the page has no text to read (a PDF) or can't be asked.
    static func look(for query: String, matchCase: Bool, wholeWords: Bool, step: Int, on page: WKWebView) async -> Matches? {
        let arguments: [String: Any] = [
            "query": query, "matchCase": matchCase, "wholeWords": wholeWords, "step": step,
            "limit": limit, "budget": budget,
        ]
        let found = try? await page.callAsyncJavaScript(script, arguments: arguments, contentWorld: .defaultClient)
        guard let found = found as? [String: Any], let index = found["index"] as? Int, let count = found["count"] as? Int else { return nil }
        return Matches(index: index, count: count, more: found["more"] as? Bool ?? false)
    }

    /// The lights off, and the match unselected unless the page has selected something else since.
    static func clear(on page: WKWebView) {
        let arguments: [String: Any] = ["query": "", "matchCase": false, "wholeWords": false, "step": 0, "limit": limit, "budget": budget]
        page.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient)
    }

    private static let script = #"""
        const state = globalThis.nerdaFind ??= {
            key: null, places: [], texts: [], matches: [], index: -1, more: false, cut: false, dirty: true,
            observers: [], highlights: new WeakMap(), selected: null
        };

        const same = (a, b) => {
            try { return a.compareBoundaryPoints(0, b) === 0 && a.compareBoundaryPoints(2, b) === 0; } catch { return false; }
        };

        // A document's two highlights are made once and only emptied after:
        // one taken out of the page's list can stay drawn until something else
        // is. Put back each time, should the page have cleared the list.
        function highlightsIn(win, doc) {
            let mine = state.highlights.get(doc);
            if (!mine) {
                mine = { all: new win.Highlight(), current: new win.Highlight() };
                mine.all.priority = 1;
                mine.current.priority = 2;
                state.highlights.set(doc, mine);
            }
            if (win.CSS.highlights.get('nerda-find') !== mine.all) win.CSS.highlights.set('nerda-find', mine.all);
            if (win.CSS.highlights.get('nerda-find-current') !== mine.current) win.CSS.highlights.set('nerda-find-current', mine.current);
            return mine;
        }

        function unpaint() {
            for (const { doc } of state.places) {
                const mine = state.highlights.get(doc);
                mine?.all.clear();
                mine?.current.clear();
            }
        }

        function deselect() {
            const match = state.selected;
            state.selected = null;
            if (!match) return;
            state.highlights.get(match.doc)?.current.clear();
            try {
                const selection = match.win.getSelection();
                if (selection.rangeCount === 1 && same(selection.getRangeAt(0), match.range)) selection.removeAllRanges();
            } catch {}
        }

        function clear() {
            deselect();
            unpaint();
            for (const observer of state.observers) observer.disconnect();
            Object.assign(state, { key: null, places: [], texts: [], matches: [], index: -1, more: false, dirty: true, observers: [] });
        }

        if (!query) return clear();
        if (document.contentType === 'application/pdf') return null;

        // The page and the frames in it that are shown and of its own site;
        // another site's can't be read.
        function places() {
            const found = [];
            (function visit(win) {
                let doc;
                try { doc = win.document; } catch { return; }
                if (!doc?.body || (win !== window && !win.frameElement?.checkVisibility())) return;
                found.push({ win, doc });
                for (let i = 0; i < win.frames.length; i++) visit(win.frames[i]);
            })(window);
            return found;
        }

        const skipped = new Set(['script', 'style', 'noscript', 'template', 'head', 'title', 'select', 'textarea',
                                 'iframe', 'frame', 'object', 'video', 'audio', 'canvas']);
        const [accept, reject, skip] = [1, 2, 3];

        // The text shown, as one string with where each piece came from. A
        // line break between blocks keeps "end" and "Start" of two paragraphs
        // apart, as on screen.
        function read({ win, doc }) {
            const nodes = [], starts = [], hidden = new Set(), blocks = new Map();
            let text = '', gap = false, block = null;
            const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, node => {
                if (node.nodeType === Node.TEXT_NODE) return hidden.has(node.parentNode) ? reject : accept;
                // Each element's style is asked for, which is what costs.
                if (--state.budget < 0) { state.cut = true; return reject; }
                if (skipped.has(node.localName)) return reject;
                if (node.localName === 'br') { gap = true; return reject; }
                const style = win.getComputedStyle(node);
                const display = style.display;
                if (display === 'none' || (display !== 'contents' && !node.checkVisibility())) return reject;
                if (style.visibility !== 'visible') hidden.add(node);
                const inline = display.startsWith('inline') || display === 'contents';
                blocks.set(node, inline ? blocks.get(node.parentNode) ?? node.parentNode : node);
                return skip;
            });
            for (let node; state.budget >= 0 && (node = walker.nextNode());) {
                const its = blocks.get(node.parentNode) ?? node.parentNode;
                if ((gap || its !== block) && text) text += '\n';
                gap = false;
                block = its;
                nodes.push(node);
                starts.push(text.length);
                text += node.data;
            }
            return { text, nodes, starts, ...fold(text) };
        }

        // Accents let go of, as WebKit's own find does, with Match Case too:
        // "ete" finds "été", "uber" "über", "strasse" "Straße". Each unit of
        // what is left maps back to the letter it came from (`from`, `to`),
        // a mark dropped onto the letter before it, so a match lights the
        // whole of its letters.
        function fold(text) {
            if (!/[^\x00-\x7f]/.test(text)) return { folded: text };
            let folded = '';
            const from = [], to = [];
            for (let i = 0; i < text.length;) {
                const code = text.codePointAt(i);
                const size = code > 0xffff ? 2 : 1;
                const letter = text.slice(i, i + size);
                const plain = code < 0xc0 ? letter : letter === 'ß' ? 'ss' : letter === 'ẞ' ? 'SS'
                    : letter.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
                if (!plain && to.length) to[to.length - 1] = i + size;
                for (let k = 0; k < plain.length; k++) { from.push(i); to.push(i + size); }
                folded += plain;
                i += size;
            }
            return { folded, from, to };
        }

        function rangeIn(doc, { nodes, starts }, from, to) {
            const at = offset => {
                let low = 0, high = starts.length - 1;
                while (low < high) {
                    const middle = (low + high + 1) >> 1;
                    if (starts[middle] <= offset) low = middle; else high = middle - 1;
                }
                return [nodes[low], Math.min(offset - starts[low], nodes[low].length)];
            };
            const range = doc.createRange();
            range.setStart(...at(from));
            range.setEnd(...at(to));
            return range;
        }

        // Shown already (not under something else, nor scrolled away in a
        // box), it stays put; otherwise it comes to the middle.
        function reveal({ win, doc, range }) {
            const box = range.getBoundingClientRect();
            const common = range.commonAncestorContainer;
            const element = common.nodeType === Node.ELEMENT_NODE ? common : common.parentElement;
            const hit = doc.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            if (!hit || !element.contains(hit)) {
                element.scrollIntoView({ block: 'center', inline: 'nearest' });
                // A paragraph taller than the window: the match, not its middle.
                const moved = range.getBoundingClientRect();
                if (moved.top < 0 || moved.bottom > win.innerHeight) win.scrollBy(0, moved.top + moved.height / 2 - win.innerHeight / 2);
            }
            for (let frame = win; frame !== window; frame = frame.parent) {
                frame.frameElement?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            }
        }

        const key = JSON.stringify([query, matchCase, wholeWords]);
        const now = places();
        if (now.length !== state.places.length || now.some((place, i) => place.doc !== state.places[i].doc)) state.dirty = true;
        for (const observer of state.observers) if (observer.takeRecords().length) state.dirty = true;

        const fresh = key !== state.key;
        let index = state.index + step;
        if (fresh || state.dirty) {
            const was = fresh ? null : state.selected?.range;
            const before = state.index;
            deselect();
            unpaint();
            // The text is read again only once the page has changed: a letter
            // more typed looks through what was read for the last.
            if (state.dirty) {
                for (const observer of state.observers) observer.disconnect();
                Object.assign(state, { places: now, budget, cut: false, dirty: false });
                state.observers = now.map(({ win, doc }) => {
                    const observer = new win.MutationObserver(() => { state.dirty = true; });
                    observer.observe(doc, { subtree: true, childList: true, characterData: true, attributes: true });
                    return observer;
                });
                state.texts = now.map(place => ({ ...place, ...read(place) }));
            }
            const word = wholeWords ? ['(?<![\\p{L}\\p{N}\\p{M}_])', '(?![\\p{L}\\p{N}\\p{M}_])'] : ['', ''];
            const pattern = new RegExp(word[0] + fold(query).folded.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+') + word[1],
                                       matchCase ? 'gu' : 'giu');
            Object.assign(state, { key, matches: [], more: state.cut });
            for (const shown of state.texts) {
                for (const found of shown.folded.matchAll(pattern)) {
                    if (state.matches.length >= limit) { state.more = true; break; }
                    const end = found.index + found[0].length;
                    const range = shown.from ? rangeIn(shown.doc, shown, shown.from[found.index], shown.to[end - 1])
                        : rangeIn(shown.doc, shown, found.index, end);
                    state.matches.push({ win: shown.win, doc: shown.doc, range });
                    highlightsIn(shown.win, shown.doc).all.add(range);
                }
            }
            // The page changed under the match on show: the same one again,
            // or the one that took its place.
            const kept = was ? state.matches.findIndex(match => same(match.range, was)) : -1;
            index = fresh ? (step < 0 ? -1 : 0) : kept >= 0 ? kept + step : Math.max(before, 0) + Math.min(step, 0);
        }

        const count = state.matches.length;
        if (!count) {
            deselect();
            state.index = -1;
            return { index: 0, count, more: state.more };
        }
        state.index = ((index % count) + count) % count;
        const match = state.matches[state.index];
        deselect();
        highlightsIn(match.win, match.doc).current.add(match.range);
        // A copy: the selection may change the range it is given as it changes.
        const selection = match.win.getSelection();
        selection.removeAllRanges();
        selection.addRange(match.range.cloneRange());
        state.selected = match;
        reveal(match);
        return { index: state.index + 1, count, more: state.more };
        """#
}
