import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import Nerda

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    try #require(condition(), "Timed out waiting for WebKit")
}

private func readinessFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Serves real pages and one interrupted, range-resumable download locally.
@MainActor
private final class ReadinessServer {
    let listener: NWListener
    var requests: [String] = []
    var interrupt = true
    let bytes = Data(repeating: 0x61, count: 512 * 1024)

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    self.requests.append(request)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    var status = "200 OK"
                    var headers = "Content-Type: text/html\r\nAccess-Control-Allow-Origin: *\r\n"
                    var body = Data("<input id='draft'><iframe src='/frame'></iframe>".utf8)
                    if path == "/frame" { body = Data("<input id='user' autocomplete='username'><input id='password' type='password'>".utf8) }
                    var length = body.count
                    if path == "/file" || path == "/slow" {
                        headers = "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=readiness.bin\r\nAccept-Ranges: bytes\r\nETag: \"fixture\"\r\nLast-Modified: Wed, 30 Sep 2026 00:00:00 GMT\r\n"
                        let range = request.lowercased().split(separator: "\n").first { $0.hasPrefix("range: bytes=") }
                        let start = range.flatMap { Int($0.dropFirst(13).split(separator: "-").first ?? "") } ?? 0
                        if range != nil {
                            status = "206 Partial Content"
                            headers += "Content-Range: bytes \(start)-\(self.bytes.count - 1)/\(self.bytes.count)\r\n"
                        }
                        body = self.bytes.dropFirst(start)
                        length = body.count
                        if self.interrupt { self.interrupt = false; body = body.prefix(64 * 1024) }
                    }
                    let head = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(length)\r\nConnection: close\r\n\r\n"
                    if path == "/slow", status == "200 OK" {
                        let rest = Data(body.dropFirst(64 * 1024))
                        connection.send(content: Data(head.utf8) + body.prefix(64 * 1024), completion: .contentProcessed { _ in })
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            connection.send(content: rest, completion: .contentProcessed { _ in connection.cancel() })
                        }
                        return
                    }
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String = "/") async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://127.0.0.1:\(try #require(listener.port).rawValue)\(path)")!
    }
}

@MainActor
private final class SiteNavigation: NSObject, WKNavigationDelegate {
    let settings = SiteSettings(defaults: nil)
    var lists: [WKContentRuleList] = []
    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.targetFrame?.isMainFrame ?? true { settings.applyBlocking(to: preferences, for: action.request.url, lists: lists) }
        return (.allow, preferences)
    }
}

@MainActor
private final class LoginFrame: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if !message.frameInfo.isMainFrame { frame = message.frameInfo }
    }
}

@Suite(.serialized)
@MainActor
struct ReadinessTests {
    @Test func closedTabsRestoreStateWithoutKeepingTheirPages() throws {
        let browser = Browser(dataStore: .nonPersistent())
        // Private tabs are never retained, even in memory for reopening.
        browser.add(Nerda.Tab(restoring: .init(url: URL(string: "https://private.test"), title: "Private", state: nil, zoom: 1, pinned: nil, home: nil)))
        browser.close(browser.tabs[0].id)
        #expect(browser.recentlyClosed.isEmpty)

        let normal = Browser()
        let saved = Session.Tab(url: URL(string: "https://example.test"), title: "Example", state: Data([1, 2]), zoom: 1.5,
                                pinned: nil, home: nil, name: "Research")
        normal.add(Nerda.Tab(restoring: saved))
        weak let closed = normal.selected
        normal.close(try #require(normal.selectedID))
        #expect(closed == nil && normal.recentlyClosed.count == 1)
        normal.reopenClosedTab()
        #expect(normal.selected?.saved == saved)
        #expect(normal.recentlyClosed.isEmpty)
        for _ in 0..<30 {
            normal.add(Nerda.Tab(restoring: saved))
            normal.close(try #require(normal.selectedID))
        }
        #expect(normal.recentlyClosed.count == 25)
        let file = try readinessFolder().appending(path: "session.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        normal.sessionFile = file
        normal.saveSession()
        let restored = Browser()
        restored.restore(from: file, loadingPins: false)
        #expect(restored.recentlyClosed.count == 25)
    }

    @Test func editedFramesStayAwakeAndCannotCloseSilently() async throws {
        let server = try ReadinessServer()
        defer { server.listener.cancel() }
        let browser = Browser(dataStore: .nonPersistent())
        defer { browser.closeAll() }
        let tab = browser.open(try await server.url())
        try await waitFor { !tab.webView.isLoading && tab.url != nil }
        // A page's own events are not an edit; typing is (execCommand's are trusted, as keys are).
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('input').dispatchEvent(new Event('input', {bubbles:true}))")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!tab.hasUnsavedWork)
        _ = try await tab.webView.evaluateJavaScript("""
            (() => { const frame = document.querySelector('iframe').contentDocument;
                     frame.getElementById('user').focus(); frame.execCommand('insertText', false, 'x'); })()
            """)
        try await waitFor { tab.hasUnsavedWork }
        #expect(await tab.isBusy())
        browser.newTab()
        tab.sleep()
        browser.sleepIdleTabs(unseenFor: 0, pinsToo: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!tab.isAsleep)
        browser.close(tab.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.tabs.contains { $0 === tab })
        browser.close(tab.id, discarding: true)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    @Test func sitePermissionsKeepOriginsAndPrivatePreferencesApart() {
        let settings = SiteSettings(defaults: nil)
        let url = URL(string: "https://example.com")!
        var options = SiteSettings.Options()
        options.camera = .allow
        options.microphone = .block
        settings.set(options, for: url)
        #expect(settings.options(for: URL(string: "https://example.com:443/path")) == options)
        #expect(settings.options(for: URL(string: "http://example.com")) == .init())
        #expect(settings.options(for: URL(string: "https://example.com:444")) == .init())
        #expect(settings.options(for: URL(string: "https://sub.example.com")) == .init())
        #expect(SiteSettings.mediaDecision(options: options, type: .camera) == .grant)
        #expect(SiteSettings.mediaDecision(options: options, type: .cameraAndMicrophone) == .deny)
        options.microphone = .ask
        #expect(SiteSettings.mediaDecision(options: options, type: .cameraAndMicrophone) == .prompt)
        #expect(SiteSettings(defaults: nil).options(for: url) == .init())
    }

    @Test func sitesNotAnsweredForGetWhatSettingsGivesEverySite() {
        let kind = SiteSettings.Kind.location
        UserDefaults.standard.set(SiteSettings.Permission.block.rawValue, forKey: kind.fallbackKey)
        defer { UserDefaults.standard.removeObject(forKey: kind.fallbackKey) }
        let settings = SiteSettings(defaults: nil)
        let asked = URL(string: "https://example.com")!, allowed = URL(string: "https://maps.example.com")!
        var options = SiteSettings.Options()
        options.location = .allow
        settings.set(options, for: allowed)
        #expect(settings.resolved(for: asked).location == .block)
        #expect(settings.resolved(for: allowed).location == .allow)
        #expect(settings.options(for: asked).location == .ask)
        #expect(kind.choices == [.allow, .block])
        UserDefaults.standard.removeObject(forKey: kind.fallbackKey)
        #expect(settings.resolved(for: asked).location == .ask)
    }

    @Test func siteSettingsSavedBeforeNotificationsKeepTheirChoices() throws {
        let saved = #"{"https://example.com:443":{"blocksAds":false,"camera":"allow","microphone":"block","location":"ask"}}"#
        let defaults = try #require(UserDefaults(suiteName: "nerda-site-settings-\(UUID())"))
        defaults.set(Data(saved.utf8), forKey: "siteSettings")
        let settings = SiteSettings(defaults: defaults)
        let url = URL(string: "https://example.com")!
        let options = settings.options(for: url)
        #expect(!options.blocksAds && options.camera == .allow && options.microphone == .block && options.notifications == .ask)
        #expect(settings.notificationPermissions.isEmpty)
        var allowed = options
        allowed.notifications = .allow
        settings.set(allowed, for: url)
        var blocked = SiteSettings.Options()
        blocked.notifications = .block
        settings.set(blocked, for: URL(string: "http://localhost:8080")!)
        #expect(settings.notificationPermissions == ["https://example.com": true, "http://localhost:8080": false])
    }

    @Test func nativePasskeysAreMaskedOnlyWithoutAuthorization() {
        let authorized = WKUserContentController(), fallback = WKUserContentController()
        Passwords.install(in: authorized, nativePasskeys: true)
        Passwords.install(in: fallback, nativePasskeys: false)
        #expect(!authorized.userScripts.contains { $0.source == Passwords.withoutPasskeys })
        #expect(fallback.userScripts.contains { $0.source == Passwords.withoutPasskeys })
    }

    @Test func iframePasswordsFillOnlyTheRequestingOrigin() async throws {
        let server = try ReadinessServer()
        defer { server.listener.cancel() }
        let frame = LoginFrame()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Passwords.install(in: configuration.userContentController)
        configuration.userContentController.add(frame, contentWorld: .defaultClient, name: "readinessFrame")
        configuration.userContentController.addUserScript(WKUserScript(source: "webkit.messageHandlers.readinessFrame.postMessage(true)",
                                                                      injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.load(URLRequest(url: try await server.url()))
        try await waitFor { !page.isLoading && frame.frame != nil }
        let target = try #require(frame.frame)
        let fill = "return nerdaFill('fixture-user', 'fixture-password', site, false)"
        #expect(try await page.callAsyncJavaScript(fill, arguments: ["site": "attacker.test"], in: target, contentWorld: Passwords.world) as? Bool == false)
        #expect(try await page.callAsyncJavaScript(fill, arguments: ["site": "127.0.0.1"], in: target, contentWorld: Passwords.world) as? Bool == true)
        #expect(try await page.evaluateJavaScript("document.getElementById('draft').value") as? String == "")
        #expect(try await page.evaluateJavaScript("document.querySelector('iframe').contentDocument.getElementById('password').value") as? String == "fixture-password")
    }

    @Test func perSiteBlockingKeepsSharedPopupsAndExtensionRulesIndependent() async throws {
        let folder = try readinessFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try ReadinessServer()
        defer { server.listener.cancel() }
        let store = try #require(WKContentRuleListStore(url: folder))
        let rule = try #require(try await store.compileContentRuleList(forIdentifier: "nerda-fixture", encodedContentRuleList: #"[{"trigger":{"url-filter":"/ads","resource-type":["raw"]},"action":{"type":"block"}}]"#))
        let extensionRule = try #require(try await store.compileContentRuleList(forIdentifier: "extension-fixture", encodedContentRuleList: #"[{"trigger":{"url-filter":"/extension","resource-type":["raw"]},"action":{"type":"block"}}]"#))
        let navigation = SiteNavigation()
        navigation.lists = [rule]
        let url = try await server.url()
        var options = SiteSettings.Options()
        options.blocksAds = false
        navigation.settings.set(options, for: url)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rule)
        configuration.userContentController.add(extensionRule)
        let first = WKWebView(frame: .zero, configuration: configuration)
        let popup = WKWebView(frame: .zero, configuration: configuration)
        first.navigationDelegate = navigation
        popup.navigationDelegate = navigation
        first.load(URLRequest(url: url))
        let other = URL(string: url.absoluteString.replacing("127.0.0.1", with: "localhost"))!
        popup.load(URLRequest(url: other))
        try await waitFor { first.url != nil && popup.url != nil && !first.isLoading && !popup.isLoading }
        func fetch(_ page: WKWebView, _ path: String) async throws -> Bool {
            try await page.callAsyncJavaScript("try { return (await fetch(path, {cache:'no-store'})).ok; } catch { return false; }",
                                              arguments: ["path": path], contentWorld: .page) as? Bool == true
        }
        #expect(try await fetch(first, "/ads"))
        #expect(try await !fetch(popup, "/ads"))
        #expect(try await !fetch(first, "/extension"))
        first.load(URLRequest(url: other))
        try await waitFor { first.url == other && !first.isLoading }
        #expect(try await !fetch(first, "/ads"))
    }

    @Test func bookmarkExportRoundTripsFoldersAndEscapedText() {
        let items = [Bookmarks.Item(title: "Work & <friends>", children: [
            .init(title: "A \"quoted\" page", url: URL(string: "https://example.com/?a=1&b=2")),
            .init(title: "Empty", children: []),
        ])]
        let imported = Bookmarks.parse(html: Bookmarks.html(items))
        #expect(imported.first?.title == items.first?.title)
        #expect(imported.first?.children?.first?.title == "A \"quoted\" page")
        #expect(imported.first?.children?.first?.url == items.first?.children?.first?.url)
        #expect(imported.first?.children?.last?.children == [])
    }

    @Test func interruptedDownloadsResumeWithTheSameRowAndBytes() async throws {
        let folder = try readinessFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try ReadinessServer()
        defer { server.listener.cancel() }
        let browser = Browser(dataStore: .nonPersistent())
        browser.downloadFolder = folder
        defer { browser.closeAll() }
        let tab = browser.open(URL(string: "about:blank")!)
        try await waitFor { !tab.webView.isLoading && tab.url != nil }
        #expect(await browser.download(try await server.url("/file")))
        let item = try #require(browser.downloads.first)
        try await waitFor { item.state == .failed }
        try #require(item.canResume)
        let id = item.id
        browser.resume(item)
        browser.resume(item)
        try await waitFor { item.state == .finished || item.state == .failed }
        #expect(item.state == .finished)
        #expect(browser.downloads.count == 1 && item.id == id)
        #expect(try Data(contentsOf: #require(item.file)) == server.bytes)
        #expect(server.requests.contains { $0.lowercased().contains("range: bytes=") })
        var post = URLRequest(url: try await server.url("/file"))
        post.httpMethod = "POST"
        #expect(!Downloads.canRetry(post))

        #expect(await browser.download(try await server.url("/slow")))
        let paused = try #require(browser.downloads.first)
        try await waitFor { paused.received > 0 }
        paused.pause()
        try await waitFor { paused.canResume }
        #expect(paused.state == .paused)
        browser.clearDownloads()
        #expect(browser.downloads.count == 1 && browser.downloads.first === paused)
        browser.close(tab.id)
        #expect(browser.tabs.count == 1)
        browser.resume(paused)
        try await waitFor { paused.state == .finished || paused.state == .failed }
        #expect(paused.state == .finished)
        #expect(try Data(contentsOf: #require(paused.file)) == server.bytes)

        // Resuming woke no page; a download from a page needs one.
        #expect(browser.selected?.page == nil)
        let blank = browser.open(URL(string: "about:blank")!)
        try await waitFor { !blank.webView.isLoading && blank.url != nil }

        // Cancelling while WebKit creates a resumed task must win.
        server.interrupt = true
        #expect(await browser.download(try await server.url("/file")))
        let cancelled = try #require(browser.downloads.first)
        try await waitFor { cancelled.state == .failed }
        try #require(cancelled.canResume)
        browser.resume(cancelled)
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(cancelled.state == .cancelled)
    }

    @Test func sameDocumentNavigationKeepsDrafts() {
        let page = URL(string: "https://example.test/editor?draft=1")!
        #expect(Browser.onlyChangesFragment(from: page, to: URL(string: page.absoluteString + "#section")!))
        #expect(!Browser.onlyChangesFragment(from: page, to: page))
        #expect(!Browser.onlyChangesFragment(from: page, to: URL(string: "https://example.test/other#section")!))
    }
}
