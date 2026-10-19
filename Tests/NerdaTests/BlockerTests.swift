import Foundation
import Network
import Testing
import WebKit
@testable import Nerda

/// A filter list server that answers 304 when asked for the version it has.
@MainActor
private final class ListServer {
    var version = "v1"
    var full = 0
    var unchanged = 0
    let listener: NWListener

    var body: String { "[Adblock Plus 2.0]\n||ads-\(version).example^\n" }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let response = MainActor.assumeIsolated {
                    let request = String(decoding: data ?? Data(), as: UTF8.self).lowercased()
                    if request.contains("if-none-match: \"\(self.version)\"") {
                        self.unchanged += 1
                        return "HTTP/1.1 304 Not Modified\r\nETag: \"\(self.version)\"\r\nConnection: close\r\n\r\n"
                    }
                    self.full += 1
                    return "HTTP/1.1 200 OK\r\nETag: \"\(self.version)\"\r\nContent-Length: \(self.body.utf8.count)\r\nConnection: close\r\n\r\n" + self.body
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func url() async throws -> URL {
        for _ in 0..<100 where listener.port == nil || listener.port == .any { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(listener.port?.rawValue)
        return URL(string: "http://127.0.0.1:\(port)/list.txt")!
    }
}

/// A list unchanged since it was fetched comes back as a 304, not the whole
/// list again; a changed one is fetched whole, and one that can't be had is
/// used as kept.
@MainActor
@Test func blockListsAreFetchedOnlyWhenChanged() async throws {
    let server = try ListServer()
    defer { server.listener.cancel() }
    let url = try await server.url()
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cached = folder.appending(path: "list")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
    #expect((server.full, server.unchanged) == (1, 1))
    // Not due: the copy kept, nothing asked.
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: false, session: session) == server.body)
    #expect((server.full, server.unchanged) == (1, 1))

    server.version = "v2"
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
    #expect((server.full, server.unchanged) == (2, 1))
    #expect(try String(contentsOf: cached, encoding: .utf8) == server.body)

    server.listener.cancel()
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
}

/// Compiling is skipped only for the same lists turned into rules by the same build.
@Test func compiledListsAreKnownByTheirTextAndBuild() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appending(path: "Nerda")
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: executable.path)
    let lists = "||ads.example^\n"
    let digest = Blocker.compiledDigest(of: lists, by: executable)
    #expect(Blocker.compiledDigest(of: lists, by: executable) == digest)
    #expect(Blocker.compiledDigest(of: lists + "||more.example^\n", by: executable) != digest)
    // A new build. A new URL too: a URL keeps the dates it has read, and
    // each helper is a new process anyway.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: executable.path)
    #expect(Blocker.compiledDigest(of: lists, by: URL(filePath: executable.path)) != digest)
}

/// Element-hiding lines: generic and site-scoped ones kept, with their
/// exceptions; what only uBlock or AdGuard read, and selectors that would
/// swallow others once WebKit joins them by commas, left out.
@Test func hidingLinesBecomeDisplayNoneRules() throws {
    #expect(ContentRules.hiding("##.ad") == ContentRules.Hiding(selector: ".ad"))
    #expect(ContentRules.hiding("News.example,~sub.other.example##.ad") == nil)
    #expect(ContentRules.hiding("news.example,shop.example###banner") == ContentRules.Hiding(selector: "#banner", sites: ["*news.example", "*shop.example"]))
    #expect(ContentRules.hiding("~news.example##div[data-ad]") == ContentRules.Hiding(selector: "div[data-ad]", unless: ["*news.example"]))
    #expect(ContentRules.hiding("news.example#@#.ad") == ContentRules.Hiding(selector: ".ad", sites: ["*news.example"], exception: true))
    for line in ["news.example#?#div:has(> .ad)", "news.example#$#.ad { color: red }", "##+js(nobab)", "##^script",
                 "##div:has-text(Sponsored)", "##.ad:style(height: 0)", "##.ad:upward(2)", "##[title=\"open",
                 "##.ad:not(.x", "##.ad\\", "google.*##.ad", "||ads.example^", "/path#anchor", "! ## comment"] {
        #expect(ContentRules.hiding(line) == nil, "\(line)")
    }
    // Never in the blocks.
    #expect(ContentRules.rule("##.ad") == nil)

    let rules = ContentRules.hide(["##.ad", "##.promo", "news.example##.promo", "shop.example#@#.ad", "#@#.gone", "##.gone"]
        .compactMap(ContentRules.hiding))
    let triggers = rules.map { $0["trigger"] as? [String: Any] ?? [:] }
    let selectors = rules.map { ($0["action"] as? [String: String])?["selector"] }
    #expect(selectors == [".ad", ".promo", ".promo"])
    #expect(triggers[0]["unless-domain"] as? [String] == ["*shop.example"])
    #expect(triggers[1].count == 1 && triggers[1]["url-filter"] as? String == ".*")
    #expect(triggers[2]["if-domain"] as? [String] == ["*news.example"])

    let unhidden = try #require(ContentRules.unhiding("@@||news.example^$generichide"))
    #expect((unhidden["trigger"] as? [String: Any])?["if-top-url"] as? [String] == [ContentRules.urlFilter("||news.example^")!])
    #expect(ContentRules.unhiding("@@$elemhide") == nil)
    #expect(ContentRules.unhiding("@@||news.example^$elemhide,script") == nil)
}

/// A list of dangerous sites names a site by itself, and blocks it for its
/// own pages too; Nerda finds the list a refused address is on.
@MainActor
@Test func dangerousListsBlockTheirSitesThemselves() throws {
    let site = try #require(ContentRules.rule("evil.example", dangerous: true))
    let trigger = try #require(site.0["trigger"] as? [String: Any])
    #expect(trigger["url-filter"] as? String == ContentRules.urlFilter("||evil.example^"))
    #expect(trigger["load-type"] == nil)
    #expect((ContentRules.rule("||evil.example^$all")?.0["trigger"] as? [String: Any])?["load-type"] as? [String] == ["third-party"])
    let encoded = try #require(ContentRules.encode("evil.example\n", partsOf: .max, dangerous: true))
    #expect(encoded.count == 1 && !encoded[0].contains("top-frame"))
    // uBlock's Badware risks names a site's own pages with $doc: blocked as a page there, never by an ad list.
    let page = try #require(ContentRules.rule("||scam.example^$doc", dangerous: true)?.0["trigger"] as? [String: Any])
    #expect(page["resource-type"] as? [String] == ["document"] && page["load-context"] == nil)
    #expect(ContentRules.rule("||scam.example^$doc") == nil)
    #expect(ContentRules.dangerous("||scam.example^$doc\n", blocks: URL(string: "https://scam.example/")!))

    let list = "! Title: Phishing URL Blocklist\nevil.example\n||bad.example/login^$all\n"
    #expect(ContentRules.dangerous(list, blocks: URL(string: "https://evil.example")!))
    #expect(ContentRules.dangerous(list, blocks: URL(string: "https://www.EVIL.example/pay?x=1")!))
    #expect(ContentRules.dangerous(list, blocks: URL(string: "http://bad.example/login")!))
    #expect(!ContentRules.dangerous(list, blocks: URL(string: "https://bad.example/")!))
    #expect(!ContentRules.dangerous(list, blocks: URL(string: "https://notevil.example/")!))

    let failure = Nerda.Tab.Failure.dangerous(URL(string: "https://evil.example/")!, on: FilterList.phishing.title)
    #expect(failure.dangerous == "Phishing URL Blocklist")
    #expect(failure.message.contains("evil.example is on the Phishing URL Blocklist"))
}

/// Serves one page with things lists hide, at any address.
@MainActor
private final class PageServer {
    let listener: NWListener
    nonisolated static let page = """
        <!doctype html><body><div class="ad">ad</div><div class="scoped">scoped</div><div class="keep">keep</div></body>
        """

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(PageServer.page.utf8.count)\r\nConnection: close\r\n\r\n" + PageServer.page
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func port() async throws -> UInt16 {
        for _ in 0..<100 where listener.port == nil || listener.port == .any { try await Task.sleep(for: .milliseconds(20)) }
        return try #require(listener.port?.rawValue)
    }
}

/// Opens pages as a tab does: the site's own switch decides on Nerda's lists.
@MainActor
private final class PageLoads: NSObject, WKNavigationDelegate {
    let settings = SiteSettings(defaults: nil)
    var lists: [WKContentRuleList] = []
    var done = false
    var error: NSError?

    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.targetFrame?.isMainFrame ?? true { settings.applyBlocking(to: preferences, for: action.request.url, lists: lists) }
        return (.allow, preferences)
    }
    func webView(_ page: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ page: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
        done = true
    }
}

/// Compiled lists in a real page: the parts lists hide are hidden, on every
/// site or their own, while the page itself still opens; selectors WebKit
/// can't read take nothing else with them; and a site on a list of dangerous
/// sites is refused as a page, unless its own switch lets it through.
@MainActor
@Test func compiledListsHideAndRefuseDangerousSites() async throws {
    let server = try PageServer()
    defer { server.listener.cancel() }
    let port = try await server.port()
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try #require(WKContentRuleListStore(url: folder))
    let ads = try #require(ContentRules.encode("""
        ||127.0.0.1^$~third-party
        ||localhost^$~third-party
        ##.ad
        localhost##.scoped
        ##.keep:no-such-pseudo-class
        ##.keep:has-text(keep)
        ##[class="keep
        127.0.0.1#?#.keep
        ##+js(nobab)
        """, partsOf: .max))
    #expect(ads.count == 2)
    let dangerous = try #require(ContentRules.encode("||localhost^$all\n", partsOf: .max, dangerous: true))
    var lists: [WKContentRuleList] = []
    for (index, part) in (ads + dangerous).enumerated() {
        lists.append(try #require(try await store.compileContentRuleList(forIdentifier: "part-\(index)", encodedContentRuleList: part)))
    }
    let loads = PageLoads()
    loads.lists = lists
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    lists.forEach(configuration.userContentController.add)
    let page = WKWebView(frame: .zero, configuration: configuration)
    page.navigationDelegate = loads
    defer { page.stopLoading() }
    func open(_ host: String) async throws -> NSError? {
        loads.done = false
        loads.error = nil
        page.load(URLRequest(url: URL(string: "http://\(host):\(port)/")!))
        for _ in 0..<250 where !loads.done { try await Task.sleep(for: .milliseconds(20)) }
        try #require(loads.done)
        return loads.error
    }
    func shown(_ selector: String) async throws -> Bool {
        try await page.evaluateJavaScript("getComputedStyle(document.querySelector('\(selector)')).display") as? String != "none"
    }

    // Ad lists never refuse the page itself, and still hide in it.
    #expect(try await open("127.0.0.1") == nil)
    #expect(try await !shown(".ad"))
    #expect(try await shown(".scoped"))
    #expect(try await shown(".keep"))

    let refused = try await open("localhost")
    #expect(refused?.domain == "WebKitErrorDomain" && refused?.code == 104)

    // The site's own switch lifts Nerda's lists, the dangerous sites' too.
    if SiteSettings.supportsSiteBlocking {
        var options = SiteSettings.Options()
        options.blocksAds = false
        loads.settings.set(options, for: URL(string: "http://localhost:\(port)/")!)
        #expect(try await open("localhost") == nil)
        #expect(try await shown(".ad"))
        loads.settings.set(.init(), for: URL(string: "http://localhost:\(port)/")!)
    }

    // Without the dangerous sites' list, a site-scoped rule hides on its site only.
    configuration.userContentController.remove(lists[2])
    #expect(try await open("localhost") == nil)
    #expect(try await !shown(".scoped"))
    #expect(try await !shown(".ad"))
    #expect(try await shown(".keep"))
}
