import SwiftUI
import WebKit

/// Reader, as Safari's: an article alone, in plain type, without the menus,
/// ads and comments round it. Nerda's own extractor rather than Mozilla's
/// Readability (no dependencies, #12): the paragraphs score the boxes they
/// sit in, and the best box, with those beside it that score near it, is
/// copied tag by tag from a short list into a page of Nerda's. That page
/// shows over the tab's own, which stays alive under it as it was, so
/// leaving Reader is instant. It has no scripts: none are copied, its CSP
/// allows none, and its view runs none.
enum Reader {
    /// A world of Nerda's own: the page can't see the scripts, nor change what they read.
    static let world = WKContentWorld.world(name: "Reader")

    struct Article: Equatable {
        var title: String
        var byline: String
        var site: String
        var published: String
        var lang: String
        var dir: String
        /// The article's HTML, only the tags and attributes the extractor copies.
        var content: String

        init?(_ value: Any?) {
            guard let found = value as? [String: Any], let content = found["content"] as? String else { return nil }
            func text(_ key: String) -> String { found[key] as? String ?? "" }
            title = text("title")
            byline = text("byline")
            site = text("site")
            published = text("published")
            lang = text("lang")
            dir = text("dir")
            self.content = content
        }
    }

    /// The view the article shows in, for `tab`: its cookies (an incognito
    /// tab's in memory), and no scripts of the article's. Find on Page's run
    /// in Nerda's own world, as on any page, and light matches as there.
    static func page(for tab: Tab) -> ReaderPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = tab.dataStore
        configuration.setValue(Tab.processPool, forKey: "processPool")
        configuration.applicationNameForUserAgent = Tab.applicationName
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        Find.install(in: configuration.userContentController)
        let page = ReaderPage(frame: .zero, configuration: configuration)
        page.tab = tab
        page.navigationDelegate = links
        page.uiDelegate = links
        page.pageZoom = tab.page?.pageZoom ?? PageZoom.current
        // The card's ground shows until the article is in, not a white flash in dark mode.
        Tab.set(page, "_setDrawsBackground:", false)
        return page
    }

    private static let links = Links()

    /// Links in the article open as they would on the page: in its tab, or
    /// with ⌘ or the middle button in a tab behind; one to a place in the
    /// article goes there.
    final class Links: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType != .other else { return .allow }
            guard action.navigationType == .linkActivated, let url = action.request.url,
                  let tab = (webView as? ReaderPage)?.tab else { return .cancel }
            if Browser.onlyChangesFragment(from: webView.url, to: url) { return .allow }
            if action.modifierFlags.contains(.command) || action.buttonNumber == 4, let browser = tab.delegate as? Browser {
                withAnimation(.slide) { _ = browser.openBehind(url) }
            } else {
                tab.go(to: url)
            }
            return .cancel
        }

        /// Open Link in New Window, from the right-click menu: a tab of its own.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, let browser = (webView as? ReaderPage)?.tab?.delegate as? Browser {
                withAnimation(.slide) { _ = browser.open(url) }
            }
            return nil
        }
    }

    /// The article as a page: its site, title, byline and date, then the
    /// article, in a column as wide as a book's page.
    static func html(for article: Article) -> String {
        let byline = article.byline == article.site ? "" : article.byline
        let meta = [byline, article.published].filter { !$0.isEmpty }.joined(separator: " · ")
        return """
            <!doctype html>
            <html lang="\(escaped(article.lang))" dir="\(escaped(article.dir))">
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'">
            <title>\(escaped(article.title))</title>
            <style>\(css)</style>
            </head>
            <body>
            <header>
            \(article.site.isEmpty ? "" : "<p class=\"site\">\(escaped(article.site))</p>")
            <h1>\(escaped(article.title))</h1>
            \(meta.isEmpty ? "" : "<p class=\"meta\">\(escaped(meta))</p>")
            </header>
            <article>\(article.content)</article>
            </body>
            </html>
            """
    }

    static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }

    /// Palette's ground and ink, light and dark, following Nerda's theme as
    /// the window does. Secondary text a step further from the ground than
    /// `Palette.muted`, to be read at length (WCAG AA).
    private static let css = """
        :root { color-scheme: light dark; --ground: #fff; --ink: #171717; --muted: #6e6e6e; --rule: #e6e6e6; --code: rgb(0 0 0 / .05); }
        @media (prefers-color-scheme: dark) {
            :root { --ground: #1c1c1c; --ink: #ededed; --muted: #a0a0a0; --rule: #383838; --code: rgb(255 255 255 / .07); }
        }
        html { background: var(--ground); color: var(--ink); font: 19px/1.6 -apple-system, system-ui, sans-serif; -webkit-text-size-adjust: none; }
        body { max-width: 680px; margin: 0 auto; padding: 56px 24px 96px; overflow-wrap: break-word; }
        header { margin-bottom: 36px; }
        .site, .meta { font-size: 15px; color: var(--muted); margin: 0; }
        .site { margin-bottom: 8px; }
        h1 { font-size: 34px; line-height: 1.2; margin: 0 0 12px; }
        article h2 { font-size: 1.4em; line-height: 1.3; margin: 1.8em 0 .6em; }
        article h3 { font-size: 1.2em; line-height: 1.3; margin: 1.6em 0 .5em; }
        article h4, article h5, article h6 { font-size: 1em; margin: 1.4em 0 .4em; }
        p, ul, ol, dl, blockquote, pre, table, details { margin: 0 0 1.1em; }
        li { margin-bottom: .3em; }
        a { color: LinkText; }
        img, video { display: block; max-width: 100%; height: auto; margin: 1.4em auto; }
        figure { margin: 1.6em 0; }
        figure img, figure video { margin: 0 auto; }
        figcaption { font-size: 15px; color: var(--muted); margin-top: .6em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid var(--rule); }
        pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow-x: auto; font-size: 15px; line-height: 1.45; }
        code, kbd, samp { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .88em; }
        pre code { font-size: inherit; }
        :not(pre) > code { background: var(--code); padding: .1em .3em; border-radius: 4px; }
        table { display: block; overflow-x: auto; border-collapse: collapse; font-size: 16px; }
        th, td { border: 1px solid var(--rule); padding: 6px 10px; text-align: start; vertical-align: top; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        """

    /// Box names that mark what isn't the article (Readability's idea, our
    /// own list), unless they also say they hold it.
    private static let unlikely = #"-ad-|\bads?\b|advert|banner|breadcrumb|byline|author|comment|community|cookie|consent|disqus|footer|gdpr|header|menu|\bnav|newsletter|pager|pagination|popup|promo|related|replies|share|sharing|sidebar|social|sponsor|subscribe|widget"#
    private static let maybe = #"article|body|column|content|main|story"#
    /// What counts for a box, and against it, as it is scored.
    private static let positive = #"article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story"#
    private static let negative = #"-ad-|\bads?\b|comment|contact|footer|masthead|meta|outbrain|promo|related|share|sidebar|sponsor|shopping|tags|widget|\bnav|menu|social|newsletter|subscribe"#

    /// Pages bigger than this are left alone: neither checked nor offered.
    private static let maxElements = 60_000

    /// Whether the page reads as an article, asked once it has loaded and
    /// the page is idle: enough long paragraphs outside the boxes that are
    /// plainly not one. The first 300 looked at, at most, and no layout asked for.
    static let probe = #"""
        await new Promise(done => typeof requestIdleCallback === 'function' ? requestIdleCallback(done, { timeout: 2000 }) : setTimeout(done, 300));
        const body = document.body;
        if (!body || document.contentType !== 'text/html' || document.getElementsByTagName('*').length > \#(maxElements)) return false;
        const unlikely = /\#(unlikely)/i, maybe = /\#(maybe)/i;
        const nodes = body.querySelectorAll('p, pre, article');
        let score = 0;
        for (let index = 0; index < nodes.length && index < 300; index++) {
            const node = nodes[index];
            const hint = (node.getAttribute('class') || '') + ' ' + node.id;
            if (unlikely.test(hint) && !maybe.test(hint)) continue;
            if (node.closest('li, nav, aside, footer, form, [hidden], [aria-hidden="true"], [class*="comment"], [id*="comment"]')) continue;
            const length = node.textContent.trim().length;
            if (length < 140) continue;
            score += Math.sqrt(length - 140);
            if (score > 20) return true;
        }
        return false;
        """#

    /// The article: its title, byline, site and date from the page's own
    /// description of it (meta tags, JSON-LD), and its content, copied clean.
    /// Null when there is none.
    static let extract = #"""
        const body = document.body;
        if (!body || document.contentType !== 'text/html' || document.getElementsByTagName('*').length > \#(maxElements)) return null;
        const unlikely = /\#(unlikely)/i, maybe = /\#(maybe)/i, positive = /\#(positive)/i, negative = /\#(negative)/i;
        const clean = text => (text || '').replace(/\s+/g, ' ').trim();
        const textOf = element => clean(element.textContent);
        const hint = element => (element.getAttribute('class') || '') + ' ' + element.id;
        const commas = text => (text.match(/[,،、，]/g) || []).length;

        // Never the article: by tag, by role, hidden, or by a name that says so.
        const junkTags = new Set(['nav', 'aside', 'footer', 'form', 'script', 'style', 'noscript', 'template', 'object', 'embed',
            'svg', 'canvas', 'button', 'input', 'select', 'textarea', 'dialog', 'menu', 'label', 'link', 'meta']);
        const junkRoles = /^(navigation|complementary|contentinfo|banner|dialog|alertdialog|menu|menubar|search|toolbar)$/;
        const inline = new Set(['a', 'span', 'em', 'i', 'strong', 'b', 'u', 's', 'del', 'ins', 'sub', 'sup', 'small', 'mark', 'abbr',
            'cite', 'q', 'code', 'kbd', 'samp', 'var', 'time', 'br', 'img', 'picture', 'font']);
        const junkCache = new Map();
        const junk = element => {
            let known = junkCache.get(element);
            if (known === undefined) {
                const name = element.localName;
                known = junkTags.has(name) || junkRoles.test(element.getAttribute('role') || '')
                    || element.hidden || element.getAttribute('aria-hidden') === 'true'
                    || /display:\s*none|visibility:\s*hidden/i.test(element.getAttribute('style') || '')
                    // A page's outer box named for a sidebar it has (has-sidebar) still holds the article.
                    || !inline.has(name) && !['body', 'article', 'main'].includes(name)
                        && unlikely.test(hint(element)) && !maybe.test(hint(element)) && !element.querySelector('article, main');
                junkCache.set(element, known);
            }
            return known;
        };

        // Each paragraph scores its box, and less so the boxes round that.
        const base = { div: 5, article: 10, main: 5, section: 2, pre: 3, td: 3, blockquote: 3, address: -3, ol: -3, ul: -3,
            dl: -3, dd: -3, dt: -3, li: -3, form: -3, header: -3, th: -5, h1: -5, h2: -5, h3: -5, h4: -5, h5: -5, h6: -5 };
        const weight = element => (positive.test(hint(element)) ? 25 : 0) - (negative.test(hint(element)) ? 25 : 0);
        const scores = new Map();
        const add = (element, points) => {
            if (!scores.has(element)) scores.set(element, (base[element.localName] || 0) + weight(element));
            scores.set(element, scores.get(element) + points);
        };
        let examined = 0;
        for (const node of body.querySelectorAll('p, pre, td, div')) {
            if (++examined > 20000) break;
            let text = '';
            if (node.localName === 'div') {
                // Text set straight in a box, between <br>s, is a paragraph too.
                for (const child of node.childNodes) if (child.nodeType === Node.TEXT_NODE) text += child.data;
                text = clean(text);
            } else {
                text = textOf(node);
            }
            if (text.length < 25) continue;
            let skip = false;
            for (let element = node; element && element !== body; element = element.parentElement) {
                if (junk(element)) { skip = true; break; }
            }
            if (skip) continue;
            const points = 1 + commas(text) + Math.min(Math.floor(text.length / 100), 3);
            let element = node.localName === 'div' ? node : node.parentElement;
            for (const share of [1, 2, 6]) {
                if (!element || element === document.documentElement) break;
                add(element, points / share);
                element = element.parentElement;
            }
        }

        // Less what of it is links: a list of links scores for nothing.
        const linkDensity = (element, length = textOf(element).length) => {
            if (!length) return 0;
            let links = 0;
            for (const link of element.querySelectorAll('a')) {
                links += textOf(link).length * ((link.getAttribute('href') || '').startsWith('#') ? 0.3 : 1);
            }
            return links / length;
        };
        const final = new Map();
        let top = null, best = 0;
        for (const [element, score] of scores) {
            const value = score * (1 - linkDensity(element));
            final.set(element, value);
            if (value > best) { best = value; top = element; }
        }
        if (!top) return null;

        // An article split into boxes side by side: those beside the best that score near it.
        const threshold = Math.max(10, best * 0.2);
        const parent = top.parentElement;
        const parts = [];
        for (const sibling of parent && parent !== document.documentElement ? parent.children : [top]) {
            if (sibling === top) { parts.push(sibling); continue; }
            if (junk(sibling)) continue;
            const alike = sibling.getAttribute('class') && sibling.getAttribute('class') === top.getAttribute('class');
            if ((final.get(sibling) ?? -Infinity) + (alike ? best * 0.2 : 0) >= threshold) { parts.push(sibling); continue; }
            if (sibling.localName === 'p') {
                const text = textOf(sibling), density = linkDensity(sibling, text.length);
                if (text.length > 80 && density < 0.25 || text.length && text.length <= 80 && density === 0 && /\.( |$)/.test(text)) parts.push(sibling);
            }
        }

        // Copied into a page of its own, tag by tag from this list; others
        // give only what is in them. Attributes only these.
        const out = document.implementation.createHTMLDocument('');
        const root = out.createElement('div');
        const roots = new Set(parts);
        const keep = { p: 'p', h1: 'h2', h2: 'h2', h3: 'h3', h4: 'h4', h5: 'h5', h6: 'h6', blockquote: 'blockquote', pre: 'pre',
            ul: 'ul', ol: 'ol', li: 'li', dl: 'dl', dt: 'dt', dd: 'dd', figure: 'figure', figcaption: 'figcaption',
            table: 'table', thead: 'thead', tbody: 'tbody', tfoot: 'tfoot', tr: 'tr', th: 'th', td: 'td', caption: 'caption',
            a: 'a', em: 'em', i: 'i', strong: 'strong', b: 'b', u: 'u', s: 's', del: 'del', ins: 'ins', sub: 'sub', sup: 'sup',
            small: 'small', mark: 'mark', abbr: 'abbr', cite: 'cite', q: 'q', code: 'code', kbd: 'kbd', samp: 'samp', var: 'var',
            time: 'time', br: 'br', hr: 'hr', details: 'details', summary: 'summary',
            div: 'div', section: 'div', article: 'div', main: 'div', header: 'div', hgroup: 'div', center: 'div', address: 'p' };
        const allowed = { td: ['colspan', 'rowspan'], th: ['colspan', 'rowspan', 'scope'], ol: ['start', 'reversed', 'type'],
            li: ['value'], abbr: ['title'], time: ['datetime'], a: ['title'] };
        const boxes = new Set(['div', 'section', 'article', 'main', 'header', 'ul', 'ol', 'dl', 'table']);
        const address = (value, schemes) => {
            if (!value) return null;
            try {
                const url = new URL(value.trim(), document.baseURI);
                return schemes.test(url.protocol) ? url.href : null;
            } catch { return null; }
        };
        const largest = srcset => {
            let pick = null, size = 0;
            for (const candidate of (srcset || '').split(/,\s+/)) {
                const [url, descriptor = '1x'] = candidate.trim().split(/\s+/);
                const value = parseFloat(descriptor) || 1;
                if (url && value >= size) { pick = url; size = value; }
            }
            return pick;
        };
        // A lazy-loaded image's real address first: what it shows until
        // scrolled to is a placeholder.
        const imageSource = image => {
            for (const value of [image.getAttribute('data-src'), image.getAttribute('data-lazy-src'), image.getAttribute('data-original'),
                largest(image.getAttribute('data-srcset')), image.currentSrc, largest(image.getAttribute('srcset')), image.getAttribute('src')]) {
                if (!value || value.startsWith('data:') && value.length < 1000) continue;
                const url = address(value, /^(https?|data):$/);
                if (url) return url;
            }
            return null;
        };
        const image = (node, into) => {
            const src = imageSource(node);
            const loaded = node.currentSrc === src;
            const width = +node.getAttribute('width') || (loaded ? node.naturalWidth : 0);
            const height = +node.getAttribute('height') || (loaded ? node.naturalHeight : 0);
            // Icons and tracking pixels; an emoji drawn as one leaves its character.
            if (width && height && width < 32 && height < 32) { if (node.alt) into.append(node.alt); return; }
            if (!src) return;
            const element = out.createElement('img');
            element.setAttribute('src', src);
            if (node.alt) element.setAttribute('alt', node.alt);
            into.append(element);
        };
        // A video from YouTube or Vimeo as a link to it: the player needs the scripts Reader doesn't run.
        const embed = (frame, into) => {
            const source = frame.getAttribute('src') || frame.getAttribute('data-src') || '';
            const youtube = source.match(/youtube(?:-nocookie)?\.com\/embed\/([\w-]+)/), vimeo = source.match(/player\.vimeo\.com\/video\/(\d+)/);
            if (!youtube && !vimeo) return;
            const paragraph = out.createElement('p'), link = out.createElement('a');
            link.setAttribute('href', youtube ? 'https://www.youtube.com/watch?v=' + youtube[1] : 'https://vimeo.com/' + vimeo[1]);
            link.textContent = 'Watch the video on ' + (youtube ? 'YouTube' : 'Vimeo');
            paragraph.append(link);
            into.append(paragraph);
        };
        const video = (node, into) => {
            const src = address(node.currentSrc || node.getAttribute('src') || node.querySelector('source[src]')?.getAttribute('src'), /^https?:$/);
            if (!src) return;
            const element = out.createElement('video');
            element.setAttribute('src', src);
            element.setAttribute('controls', '');
            element.setAttribute('preload', 'metadata');
            const poster = address(node.getAttribute('poster'), /^https?:$/);
            if (poster) element.setAttribute('poster', poster);
            into.append(element);
        };
        // A box inside the article that is mostly links (share, tags,
        // related), or scores against itself, is left out.
        const worth = element => {
            const text = textOf(element);
            if (!text) return !!element.querySelector('img, picture, video, iframe');
            const own = weight(element);
            if ((final.get(element) || 0) + own < 0) return false;
            if (commas(text) >= 10) return true;
            const density = linkDensity(element, text.length);
            if (own < 25 && density > 0.2 || density > 0.5) return false;
            return text.length >= 25 || !!element.querySelector('h1, h2, h3, h4, h5, h6, img, picture, video, iframe, pre, table');
        };
        let budget = 50000;
        const copy = (from, into) => {
            for (const node of from.childNodes) {
                if (--budget < 0) return;
                if (node.nodeType === Node.TEXT_NODE) { into.append(node.data); continue; }
                if (node.nodeType !== Node.ELEMENT_NODE || junk(node)) continue;
                const name = node.localName;
                if (name === 'img') { image(node, into); continue; }
                if (name === 'picture') { const inner = node.querySelector('img'); if (inner) image(inner, into); continue; }
                if (name === 'iframe') { embed(node, into); continue; }
                if (name === 'video') { video(node, into); continue; }
                if (boxes.has(name) && !worth(node)) continue;
                const tag = keep[name];
                if (!tag) { copy(node, into); continue; }
                const element = out.createElement(tag);
                for (const attribute of allowed[name] || []) {
                    const value = node.getAttribute(attribute);
                    if (value !== null) element.setAttribute(attribute, value);
                }
                // Kept for a link to a place in the article (a footnote).
                if (node.id) element.id = node.id;
                if (name === 'a') {
                    const href = address(node.getAttribute('href'), /^(https?|mailto):$/);
                    if (href) element.setAttribute('href', href);
                }
                copy(node, element);
                into.append(element);
            }
        };
        for (const part of parts) {
            // A cell or an item, as the best box, can't stand alone outside its table or list.
            const tag = /^(p|h[1-6]|pre|blockquote|ul|ol|figure|table)$/.test(part.localName) ? keep[part.localName] : 'div';
            const element = out.createElement(tag);
            copy(part, element);
            root.append(element);
        }

        // About the article, from what the page says of itself.
        const meta = (...names) => {
            for (const name of names) {
                const value = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`)?.getAttribute('content');
                if (value?.trim()) return value.trim();
            }
            return '';
        };
        let data = {};
        for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
            try {
                const items = [].concat(JSON.parse(script.textContent)).flatMap(item => item?.['@graph'] ? [].concat(item['@graph']) : [item]);
                const found = items.find(item => /Article|Posting|Report/.test([].concat(item?.['@type'] || []).join(' ')));
                if (found) { data = found; break; }
            } catch {}
        }
        const names = value => [].concat(value || []).map(one => typeof one === 'string' ? one : one?.name).filter(Boolean).join(', ');
        // The title as Safari picks it. The tab's title is often the article's
        // then the site's, after the last " - ", " | " or " — "; a JSON-LD
        // headline may be a summary instead (Wikipedia's), so it is only
        // taken when it reads like the tab's title.
        const tabTitle = clean(document.title);
        const cut = /^(.+)\s[-|–—]\s(.+)$/.exec(tabTitle);
        const titled = cut && cut[2].length < cut[1].length ? cut[1].trim() : tabTitle;
        const ogTitle = clean(meta('og:title', 'twitter:title'));
        const lower = text => text.toLowerCase();
        const heading = clean(document.querySelector('h1')?.textContent);
        const own = heading !== '' && heading.length >= titled.length / 2
            && [tabTitle, ogTitle].some(whole => lower(whole).startsWith(lower(heading)));
        const alike = text => text && (lower(titled).includes(lower(text)) || lower(text).includes(lower(titled)));
        const title = (own ? heading : '') || ogTitle || [data.headline, data.name].map(clean).find(alike) || titled;
        let byline = clean(names(data.author) || meta('author') || document.querySelector('[rel="author"], [itemprop="author"]')?.textContent);
        if (byline.length > 100 || /^https?:/.test(byline)) byline = '';
        const site = clean(meta('og:site_name') || (titled !== tabTitle ? cut[2] : '') || location.hostname.replace(/^www\./, ''));
        const raw = data.datePublished || meta('article:published_time', 'date')
            || document.querySelector('[itemprop="datePublished"]')?.getAttribute('content')
            || document.querySelector('article time[datetime], time[pubdate]')?.getAttribute('datetime');
        const date = raw ? new Date(raw) : null;
        const published = date && !isNaN(date) ? date.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' }) : '';

        // The title shows above the article: not again as its first heading. Nor what is left empty.
        [...root.querySelectorAll('h2')].find(heading => textOf(heading).toLowerCase() === title.toLowerCase())?.remove();
        for (const element of [...root.querySelectorAll('p, div, li, figure, blockquote, h2, h3, h4, h5, h6')].reverse()) {
            if (!element.textContent.trim() && !element.querySelector('img, video')) element.remove();
        }
        if (textOf(root).length < 200) return null;
        return { title, byline, site, published, lang: document.documentElement.lang || '', dir: document.dir || '', content: root.innerHTML };
        """#
}

/// The view Reader shows in, knowing its tab, for its links.
final class ReaderPage: WKWebView {
    weak var tab: Tab?
}

/// A tab's Reader, over its page, taking the keyboard as it comes so Space
/// and the arrows scroll the article.
struct ReaderView: NSViewRepresentable {
    let page: ReaderPage
    let takesFocus: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        page.frame = view.bounds
        page.autoresizingMask = [.width, .height]
        view.addSubview(page)
        if takesFocus {
            // A turn later: the window is only there once SwiftUI has put the view in it.
            DispatchQueue.main.async { [page] in page.window?.makeFirstResponder(page) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

extension Tab {
    /// Whether the page reads as an article, so the address bar offers
    /// Reader: once it has loaded, or `delay` after it changed its address
    /// itself (a site's own navigation, with no load). Main frame only.
    func checkReadable(after delay: Duration = .zero) {
        readerCheck?.cancel()
        guard let page, let url = page.url, ["http", "https", "file"].contains(url.scheme ?? ""), madeFor == nil else { return }
        readerCheck = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                // A load under way is checked once it has finished.
                guard !page.isLoading else { return }
            }
            guard !Task.isCancelled else { return }
            let found = try? await page.callAsyncJavaScript(Reader.probe, contentWorld: Reader.world) as? Bool
            guard !Task.isCancelled, self.page === page, page.url == url else { return }
            readable = found == true
        }
    }

    /// A new address is a new page as far as Reader goes, but for a jump within this one.
    func readerAddressChanged(from old: URL?) {
        if let url, Browser.onlyChangesFragment(from: old, to: url) { return }
        closeReader(checked: false)
        if let page, !page.isLoading { checkReadable(after: .seconds(1)) }
    }

    /// Reader put away; and unless the page is still the same one, not offered until checked again.
    func closeReader(checked: Bool = true) {
        reader = nil
        guard !checked else { return }
        readerCheck?.cancel()
        readable = false
    }

    /// The article, over the page; or the page again, as it was left.
    func toggleReader() async {
        if reader != nil { return closeReader() }
        guard let page, let url = page.url else { return }
        let found = try? await page.callAsyncJavaScript(Reader.extract, contentWorld: Reader.world)
        guard self.page === page, page.url == url, reader == nil else { return }
        // The check said article, the page now says otherwise: no longer offered.
        guard let article = Reader.Article(found) else { return readable = false }
        let view = Reader.page(for: self)
        view.loadHTMLString(Reader.html(for: article), baseURL: url)
        reader = view
    }
}

extension Browser {
    /// View › Show Reader, or the address bar's Reader button.
    func toggleReader() {
        guard !locked, let tab = selected, tab.hasPage, tab.readable || tab.reader != nil else { return }
        Task {
            await tab.toggleReader()
            if tab.reader == nil, tab.id == selectedID { focusPage() }
        }
    }
}
