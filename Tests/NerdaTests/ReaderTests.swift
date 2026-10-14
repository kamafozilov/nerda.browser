import Testing
import WebKit
@testable import Nerda

private let address = URL(string: "https://news.example.com/2026/10/a-long-walk")!

private let paragraph = """
    The road ran north for many miles, past farms, rivers and small towns, and every one of them had a story \
    to tell about the people who had walked it before, in summer and in winter, for work, for love, or simply \
    for the walk itself.
    """

/// An article among what surrounds it on a news site: the site's menu, a
/// sidebar of other stories, share links, a form, comments and a footer.
private let article = """
    <!doctype html><html lang="en"><head><title>A Long Walk | Example News</title>
    <meta property="og:site_name" content="Example News">
    <script type="application/ld+json">{"@context": "https://schema.org", "@type": "NewsArticle", "headline": "A Long Walk",
    "author": [{"@type": "Person", "name": "Ada Byron"}], "datePublished": "2026-10-01T09:00:00Z"}</script>
    </head><body>
    <header class="site-header"><nav><a href="/">Home</a> <a href="/world">World</a> <a href="/sport">Sport</a></nav></header>
    <div class="layout has-sidebar">
    <main><article class="post">
    <h1>A Long Walk</h1>
    <p class="byline">By Ada Byron</p>
    <p>First, \(paragraph)</p>
    <p>Then, \(paragraph) <a href="/2026/09/the-start">The start</a> is where it began.</p>
    <figure><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-src="/images/walk.jpg" alt="The road">
    <figcaption>The road north.</figcaption></figure>
    <h2>The river</h2>
    <p>Later, \(paragraph)</p>
    <ul><li>One stop by the river</li><li>Another by the mill</li></ul>
    <pre><code>let miles = 120</code></pre>
    <iframe src="https://www.youtube.com/embed/abc123"></iframe>
    <script>window.bad = true</script>
    <form><input name="email"><button>Sign up</button></form>
    <div class="share-links"><a href="/share/x">Share on X</a> <a href="/share/facebook">Share on Facebook</a></div>
    <p>Last, \(paragraph)</p>
    </article></main>
    <aside class="sidebar"><h3>Most read</h3><p>Sidebar story: \(paragraph)</p></aside>
    </div>
    <section id="comments" class="comments"><p>A comment: \(paragraph)</p></section>
    <footer><p>Copyright Example News</p></footer>
    </body></html>
    """

/// Not articles: a front page of headlines, and a sign-in page.
private let notArticles = [
    """
    <html><body><nav><a href="/">Home</a></nav><main>
    \((1...20).map { "<h3><a href=\"/story/\($0)\">Story number \($0)</a></h3><p>A short teaser for the story.</p>" }.joined())
    </main></body></html>
    """,
    """
    <html><body><h1>Sign in</h1><form><input name="user"><input type="password"><button>Sign In</button></form>
    <p>Forgot your password? Reset it here.</p></body></html>
    """,
]

@MainActor
private func loaded(_ html: String) async throws -> WKWebView {
    let page = WKWebView()
    page.loadHTMLString(html, baseURL: address)
    while page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    return page
}

/// The article is picked from among the menu, the sidebar and the comments:
/// its text, headings, lists, code and picture (at its lazy-loaded address),
/// and about it, from the page's own description; nothing round it, and no
/// script or form.
@MainActor
@Test func readerPicksTheArticleFromThePage() async throws {
    let page = try await loaded(article)
    #expect(try await page.callAsyncJavaScript(Reader.probe, contentWorld: Reader.world) as? Bool == true)
    let found = try #require(Reader.Article(try await page.callAsyncJavaScript(Reader.extract, contentWorld: Reader.world)))
    #expect(found.title == "A Long Walk")
    #expect(found.byline == "Ada Byron")
    #expect(found.site == "Example News")
    #expect(found.published.contains("2026"))
    #expect(found.lang == "en")
    for kept in ["First, The road", "Then, The road", "Later, The road", "Last, The road", "<h2>The river</h2>",
                 "<li>One stop by the river</li>", "<pre><code>let miles = 120</code></pre>",
                 #"<img src="https://news.example.com/images/walk.jpg" alt="The road">"#, "The road north.",
                 #"<a href="https://news.example.com/2026/09/the-start">The start</a>"#,
                 #"<a href="https://www.youtube.com/watch?v=abc123">"#] {
        #expect(found.content.contains(kept), "\(kept)")
    }
    for left in ["Home", "Most read", "Sidebar story", "A comment", "Copyright", "Share on", "By Ada Byron",
                 "<h2>A Long Walk</h2>", "<script", "window.bad", "<form", "<input", "<button", "<iframe", "data:image"] {
        #expect(!found.content.contains(left), "\(left)")
    }
    // Shown as a page that can't run a script, its words escaped.
    let html = Reader.html(for: found)
    #expect(html.contains("Content-Security-Policy\" content=\"default-src 'none';"))
    #expect(Reader.escaped(#"<b>"Fish" & chips</b>"#) == "&lt;b&gt;&quot;Fish&quot; &amp; chips&lt;/b&gt;")
}

/// An encyclopaedia's article, as Wikipedia describes it: its JSON-LD
/// headline is a summary and its publisher the foundation, so the title is
/// its own heading and the site the end of the tab's title, as in Safari.
@MainActor
@Test func readerTitlesAnArticleAsItsPageDoes() async throws {
    let page = try await loaded("""
        <!doctype html><html lang="en"><head><title>Web browser - Wikipedia</title>
        <script type="application/ld+json">{"@context": "https://schema.org", "@type": "Article", "name": "Web browser",
        "headline": "software application for retrieving, presenting, and traversing information resources on the World Wide Web",
        "publisher": {"@type": "Organization", "name": "Wikimedia Foundation, Inc."}}</script>
        </head><body><nav><a href="/">Main page</a></nav><main>
        <h1 id="firstHeading"><span class="mw-page-title-main">Web browser</span></h1>
        <div id="bodyContent"><p>A web browser, \(paragraph)</p><p>History: \(paragraph)</p><p>Features: \(paragraph)</p></div>
        </main></body></html>
        """)
    let found = try #require(Reader.Article(try await page.callAsyncJavaScript(Reader.extract, contentWorld: Reader.world)))
    #expect(found.title == "Web browser")
    #expect(found.site == "Wikipedia")

    // With no heading of its own, the headline is taken only when it reads like the tab's title.
    let plain = try await loaded("""
        <!doctype html><html><head><title>Rivers of the north | Example News</title>
        <script type="application/ld+json">{"@type": "NewsArticle", "headline": "Rivers of the North"}</script>
        </head><body><article><p>First, \(paragraph)</p><p>Then, \(paragraph)</p></article></body></html>
        """)
    let other = try #require(Reader.Article(try await plain.callAsyncJavaScript(Reader.extract, contentWorld: Reader.world)))
    #expect(other.title == "Rivers of the North")
    #expect(other.site == "Example News")
}

/// A page that isn't an article is never offered Reader.
@MainActor
@Test(arguments: notArticles)
func readerIsNotOfferedForOtherPages(_ html: String) async throws {
    let page = try await loaded(html)
    #expect(try await page.callAsyncJavaScript(Reader.probe, contentWorld: Reader.world) as? Bool == false)
}

/// Once loaded, an article's tab offers Reader; it shows over the page and
/// goes again, the page under it the same one throughout, never reloaded.
@MainActor
@Test func readerShowsOverThePageAndGoesAgain() async throws {
    let browser = Browser()
    let tab = Tab()
    browser.add(tab)
    let page = tab.webView
    page.loadHTMLString(article, baseURL: address)
    for _ in 0..<250 where !tab.readable { try await Task.sleep(for: .milliseconds(20)) }
    #expect(tab.readable)
    _ = try await page.callAsyncJavaScript("window.still = true", contentWorld: .page)
    await tab.toggleReader()
    let reader = try #require(tab.reader)
    while reader.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    #expect(try await reader.callAsyncJavaScript("return document.querySelector('h1').textContent",
                                                contentWorld: .defaultClient) as? String == "A Long Walk")
    await tab.toggleReader()
    #expect(tab.reader == nil)
    #expect(tab.readable)
    #expect(tab.page === page)
    #expect(try await page.callAsyncJavaScript("return window.still", contentWorld: .page) as? Bool == true)
}

/// An address that can't be opened, typed over an article in Reader, shows
/// why with no Reader button: the article left under the error isn't
/// offered, then or once the tab is back at its address.
@MainActor
@Test func aPageThatFailsOffersNoReader() async throws {
    let (browser, tab, _) = try await shownReader()
    defer { browser.closeAll() }
    tab.go(to: URL(string: "https://127.0.0.1:1/")!)
    for _ in 0..<250 where tab.failure == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(tab.failure != nil)
    #expect(tab.reader == nil)
    #expect(!tab.readable)
    // The page's own check, a second after its address went back.
    try await Task.sleep(for: .milliseconds(1500))
    #expect(!tab.readable)
}

/// A tab with the article in Reader, its article in.
@MainActor
private func shownReader() async throws -> (Browser, Nerda.Tab, ReaderPage) {
    let browser = Browser(dataStore: .nonPersistent())
    let tab = Tab()
    browser.add(tab)
    tab.webView.loadHTMLString(article, baseURL: address)
    for _ in 0..<250 where !tab.readable { try await Task.sleep(for: .milliseconds(20)) }
    await tab.toggleReader()
    let reader = try #require(tab.reader)
    for _ in 0..<250 where !reader.loaded || reader.isLoading {
        try await Task.sleep(for: .milliseconds(20))
    }
    return (browser, tab, reader)
}

/// What Reader's text reads, from a world of the test's own.
@MainActor
private func text(of reader: ReaderPage) async -> String {
    (try? await reader.callAsyncJavaScript("return document.body.textContent", contentWorld: .defaultClient) as? String) ?? ""
}

/// Stands in for WebKit's own Open Link in New Window.
private final class LinkOpener: NSObject {
    @objc func open(_ sender: Any?) {}
}

/// A link followed without a click, as the right-click menu's Open Link is.
private final class MenuAction: WKNavigationAction {
    let url: URL
    init(_ url: URL) { self.url = url }
    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { .other }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var buttonNumber: Int { 0 }
}

/// A link's right-click menu in Reader is a page's: Open Link in New Tab
/// leaves the tab behind, ⌥'s Go to It goes there, and Open Link goes in
/// the tab itself, leaving Reader.
@MainActor
@Test func readerLinksOpenFromTheMenuAsOnThePage() async throws {
    _ = NSApplication.shared
    let (browser, tab, reader) = try await shownReader()
    let front = browser.selectedID
    let menu = NSMenu()
    let opener = LinkOpener()
    let item = NSMenuItem(title: "Open Link in New Window", action: #selector(LinkOpener.open(_:)), keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    item.target = opener
    menu.addItem(item)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    reader.willOpenMenu(menu, with: event)
    #expect(menu.items.prefix(2).map(\.title) == ["Open Link in New Tab", "Open Link in New Tab and Go to It"])

    let link = URL(string: "https://news.example.com/2026/09/the-start")!
    func open() {
        _ = reader.uiDelegate?.webView?(reader, createWebViewWith: reader.configuration, for: MenuAction(link),
                                        windowFeatures: WKWindowFeatures())
    }
    menu.performActionForItem(at: 0)
    open()
    #expect(browser.tabs.count == 2)
    #expect(browser.selectedID == front)
    menu.performActionForItem(at: 1)
    open()
    #expect(browser.tabs.count == 3)
    #expect(browser.selectedID != front)

    let links = try #require(reader.navigationDelegate as? Reader.Links)
    #expect(await links.webView(reader, decidePolicyFor: MenuAction(link)) == .cancel)
    #expect(tab.url == link)
    #expect(tab.reader == nil)
}

/// File › Print… while Reader shows prints the article, as Safari does, not the page under it.
@MainActor
@Test func printingWhileReaderShowsPrintsTheArticle() async throws {
    let (_, tab, reader) = try await shownReader()
    #expect(tab.shown === reader)
    #expect(Printing.operation(for: try #require(tab.shown)).jobTitle == "A Long Walk")
    await tab.toggleReader()
    #expect(tab.shown === tab.page)
}

/// ⌘+ in Reader zooms the article alone, and the sidebar's badge says how
/// far; the page under it keeps its site's zoom.
@MainActor
@Test func readerZoomsOnItsOwn() async throws {
    let (_, tab, reader) = try await shownReader()
    let page = try #require(tab.page)
    let before = page.pageZoom
    tab.zoom(1)
    #expect(reader.pageZoom > before)
    #expect(page.pageZoom == before)
    #expect(tab.pageZoom == reader.pageZoom)
    await tab.toggleReader()
    #expect(tab.pageZoom == before)
}

/// A page translated while Reader shows: Reader reads it as translated, in
/// the language it went into, once its text has come back, and then the
/// page's own words again with Show Original.
@MainActor
@Test func readerReadsThePageAsTranslated() async throws {
    let (_, tab, reader) = try await shownReader()
    let page = try #require(tab.page)
    tab.pageLanguage = "en"
    tab.translationTargets = ["de"]
    tab.translatedTo = "de"
    let translate = "for (const p of document.querySelectorAll('p')) p.firstChild.data = p.firstChild.data.replace(from, to)"
    _ = try await page.callAsyncJavaScript(translate, arguments: ["from": "First,", "to": "Erstens,"], contentWorld: .defaultClient)
    tab.translating = true
    tab.translating = false
    for _ in 0..<100 where !(await text(of: reader)).contains("Erstens,") { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await text(of: reader).contains("Erstens,"))
    #expect(try await reader.callAsyncJavaScript("return document.documentElement.lang", contentWorld: .defaultClient) as? String == "de")
    #expect(tab.reader === reader)

    _ = try await page.callAsyncJavaScript(translate, arguments: ["from": "Erstens,", "to": "First,"], contentWorld: .defaultClient)
    tab.showOriginal()
    for _ in 0..<100 where (await text(of: reader)).contains("Erstens,") { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await text(of: reader).contains("First, The road"))
    #expect(try await reader.callAsyncJavaScript("return document.documentElement.lang", contentWorld: .defaultClient) as? String == "en")
}

/// Find on Page in Reader counts the article's matches, selects the one on
/// show and lights them, the one on show in Safari's yellow, as on a page.
@MainActor
@Test func findInReaderLightsTheMatches() async throws {
    let (browser, _, reader) = try await shownReader()
    browser.showFindBar()
    browser.findQuery = "road"
    browser.find()
    for _ in 0..<100 where browser.findMatches == nil { try await Task.sleep(for: .milliseconds(20)) }
    let count = try #require(browser.findMatches?.count)
    #expect(count > 1)
    #expect(browser.findMatches?.index == 1)
    let lit = try await reader.callAsyncJavaScript("""
        return [CSS.highlights.get('nerda-find')?.size ?? 0, CSS.highlights.get('nerda-find-current')?.size ?? 0,
                getSelection().toString(), getComputedStyle(document.body, '::highlight(nerda-find-current)').backgroundColor]
        """, contentWorld: .defaultClient) as? [Any]
    #expect(lit?[0] as? Int == count)
    #expect(lit?[1] as? Int == 1)
    #expect(lit?[2] as? String == "road")
    #expect(lit?[3] as? String == "rgb(255, 214, 10)")
    browser.hideFindBar()
}
