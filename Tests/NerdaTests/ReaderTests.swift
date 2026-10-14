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
