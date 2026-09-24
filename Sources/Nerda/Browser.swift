import SwiftUI
import WebKit

/// One browser window: its tabs, newest first, which one is showing, and what
/// is open around them. A tab only exists once there is somewhere to go, so
/// there are no empty "New Tab" tabs.
@Observable
final class Browser: NSObject {
    private(set) var tabs: [Tab] = [] {
        didSet { sessionChanged() }
    }
    var selectedID: Tab.ID? {
        didSet {
            tabs.first { $0.id == oldValue }?.lastSeen = .now
            // As in Chrome, going to another tab takes the page out of full screen.
            if selectedID != oldValue { exitPageFullscreen() }
            sessionChanged()
        }
    }
    var sidebarOpen = true
    /// Open at launch too: there are no tabs until you say where to go.
    var commandBarOpen = true {
        didSet { if commandBarOpen { exitPageFullscreen() } }
    }
    /// The tab whose page shows one of its elements (a video) over the whole
    /// window, as it asked to. Always the one on screen.
    private(set) var fullscreenTab: Tab.ID?
    /// This session's downloads, newest first.
    private(set) var downloads: [Download] = []
    /// Find in page (⌘F): the bar, what it looks for, and whether the last look found it.
    var findBarOpen = false
    var findQuery = ""
    private(set) var findMissing = false
    /// Counts ⌘Fs, so one with the bar already open still puts the keyboard in it.
    var findRequests = 0

    /// How long a tab can go unseen before it sleeps.
    // ponytail: fixed; a setting once there are settings. Edge's default is 2 hours,
    // this is shorter because staying light is the point.
    static let sleepAfter: TimeInterval = 30 * 60
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?
    /// The address last loaded again for a redirect WebKit lost, so it is only tried once.
    @ObservationIgnored private var retried: URL?
    /// Where the tabs are saved as they change (see Session); nil keeps them
    /// to this run, as in tests, and while the window is closed.
    @ObservationIgnored var sessionFile: URL?
    @ObservationIgnored var pendingSave: Task<Void, Never>?
    @ObservationIgnored var savedSession: Data?
    @ObservationIgnored private var sessionTimer: Timer?

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    override init() {
        super.init()
        // Checked each minute, loosely, so the system can fold it in with other wake-ups.
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs(unseenFor: Self.sleepAfter) }
        }
        sleepTimer?.tolerance = 15
        // What changes without telling (scrolling, a page changing its own
        // address) is saved every few seconds, and only if it did change.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        sessionTimer?.tolerance = 3
        // When the Mac runs short of memory, every tab out of sight sleeps at once.
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sleepIdleTabs(unseenFor: 0) }
        }
        memoryPressure?.activate()
    }

    /// Tabs out of sight at least this long, and not busy (playing, on a call), sleep.
    func sleepIdleTabs(unseenFor age: TimeInterval) {
        let cutoff = Date.now.addingTimeInterval(-age)
        for tab in tabs where tab.id != selectedID && !tab.isAsleep && tab.lastSeen <= cutoff {
            Task {
                // Asked of the page, so it may have come on screen in the meantime.
                if await !tab.isBusy(), tab.id != selectedID { tab.sleep() }
            }
        }
    }

    /// A tab for `url`, on screen, or for a link opened in the background
    /// (⌘-click), behind the one that is.
    func open(_ url: URL, inBackground: Bool = false) {
        add(Tab(url: url), inBackground: inBackground)
    }

    func add(_ tab: Tab, inBackground: Bool = false) {
        tab.delegate = self
        tabs.insert(tab, at: 0)
        if !inBackground { selectedID = tab.id }
    }

    /// Closing the tab on screen hands the screen back to the page that opened
    /// it (a popup's), or else to the one that slides into its place, or to
    /// the one above when there is none below, as browsers do.
    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        if selectedID == id {
            let opener = tabs.first { $0 === closed.opener }
            selectedID = opener?.id ?? (tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id)
        }
        // With nothing left, straight back to asking where to go, as at launch.
        if tabs.isEmpty { commandBarOpen = true }
    }

    /// Closing the window closes its tabs, as Safari does: nothing keeps
    /// playing, or holding memory, behind a window that is gone. They are
    /// still saved, as Chrome keeps its last window: they come back with the
    /// window, or at the next launch.
    func closeAll() {
        saveSession()
        sessionFile = nil
        tabs.removeAll()
        selectedID = nil
        commandBarOpen = true
    }

    /// ⌘1 to ⌘8, top down; ⌘9 is always the last, as in every browser.
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { selectedID = tabs[index].id }
    }

    /// ⌃Tab and ⌃⇧Tab: the next tab down, or up, round from the end to the start.
    func selectTab(after step: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = tabs[(index + step + tabs.count) % tabs.count].id
    }

    /// The next match on the page, or the one before; round to the start past the end.
    func find(backwards: Bool = false) {
        guard let page = selected?.webView, !findQuery.isEmpty else { return findMissing = false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        let query = findQuery
        Task {
            let found = (try? await page.find(query, configuration: configuration))?.matchFound ?? false
            if query == findQuery { findMissing = !found }
        }
    }

    /// A page going full screen, or coming back. Only the page on screen, and
    /// only straight after a click or key press: the page checks that too, but
    /// it could be got round there.
    func page(_ page: WKWebView, wantsFullscreen: Bool) {
        guard let tab = tab(for: page) else { return }
        guard wantsFullscreen else {
            if fullscreenTab == tab.id { fullscreenTab = nil }
            return
        }
        let sinceInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard tab.id == selectedID, !commandBarOpen, sinceInput < 1 else {
            page.evaluateJavaScript(Fullscreen.exit)
            return
        }
        fullscreenTab = tab.id
    }

    func exitPageFullscreen() {
        guard let id = fullscreenTab else { return }
        fullscreenTab = nil
        tabs.first { $0.id == id }?.page?.evaluateJavaScript(Fullscreen.exit)
    }

    func clearDownloads() {
        downloads.removeAll { $0.state != .running }
    }

    private func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.page === webView }
    }
}

/// Windows a page opens, from links with target=_blank to sign-in popups,
/// open as tabs; one that closes itself closes its tab. A page's alerts, and
/// its file pickers, come up as sheets over it.
extension Browser: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let tab = Tab(configuration: configuration)
        tab.opener = self.tab(for: webView)
        withAnimation(.slide) { add(tab) }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        withAnimation(.slide) { close(tab.id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(Self.says(frame), message, over: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(Self.says(frame), message, over: webView, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 280
        let answer = await ask(Self.says(frame), prompt, over: webView, buttons: ["OK", "Cancel"], field: field)
        return answer == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = window(showing: webView) else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private static func says(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page says" : "\(host) says"
    }

    /// A sheet over the page, whose tab comes on screen first if it wasn't:
    /// a question should show what it is about.
    private func ask(_ title: String, _ message: String, over webView: WKWebView,
                     buttons: [String] = ["OK"], field: NSTextField? = nil) async -> NSApplication.ModalResponse {
        guard let window = window(showing: webView) else { return .cancel }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await alert.beginSheetModal(for: window)
    }

    private func window(showing webView: WKWebView) -> NSWindow? {
        if let tab = tab(for: webView) { selectedID = tab.id }
        return NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }
}

extension Browser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.shouldPerformDownload { return .download }

        // mailto:, tel:, zoommtg: and the like belong to other apps, and only
        // with a yes: a page could otherwise start any app it names.
        if !Self.pageSchemes.contains(url.scheme?.lowercased() ?? "") {
            guard action.targetFrame?.isMainFrame ?? true,
                  let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return .cancel }
            let name = FileManager.default.displayName(atPath: app.path).replacing(".app", with: "")
            let answer = await ask("Open “\(name)”?", "This page wants to open \(name).", over: webView,
                                   buttons: ["Open", "Cancel"])
            if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            return .cancel
        }

        // ⌘-click or a middle click: a tab of its own, behind this one.
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            withAnimation(.slide) { open(url, inBackground: true) }
            return .cancel
        }
        return .allow
    }

    private static let pageSchemes: Set = ["http", "https", "file", "about", "data", "blob", "javascript"]

    /// What a page can't show (a zip), or is told to save (an attachment), is downloaded.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // A WebKit bug: a redirect onto a page its service worker serves
        // (youtube.com to www.youtube.com, once visited) comes with no response
        // at all, which would load blank or be saved as a file. Going to the new
        // address directly works, so that is done instead, once.
        if response.response.url == nil {
            guard response.isForMainFrame, let url = webView.url, url != retried else { return .cancel }
            retried = url
            Task { webView.load(URLRequest(url: url)) }
            return .cancel
        }
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return response.canShowMIMEType && !disposition.lowercased().hasPrefix("attachment") ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
        // A link that opened a new tab only to download leaves nothing to show in it.
        if webView.backForwardList.currentItem == nil, let tab = tab(for: webView) {
            withAnimation(.slide) { close(tab.id) }
        }
    }

    private func track(_ download: WKDownload) {
        download.delegate = self
        withAnimation(.slide) { downloads.insert(Download(download), at: 0) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        retried = nil
        tab(for: webView)?.failure = nil
        tab(for: webView)?.recordVisit()
        // A new document has nothing on show.
        if let tab = tab(for: webView), fullscreenTab == tab.id { fullscreenTab = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab(for: webView)?.pageDidLoad()
        sessionChanged()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        // Stopped, overtaken by another load, or turned into a download: nothing went wrong.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        tab(for: webView)?.failure = (url, error.localizedDescription)
    }

    /// The page's process died (out of memory, or a WebKit bug): it would stay
    /// blank, so it is loaded again, as Safari does. One out of sight sleeps
    /// instead, and loads when it is next shown: reloading it now would only
    /// add to the memory it may have died for. A page that dies again within
    /// a minute would only keep reloading, and says so instead; ⌘R tries again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if fullscreenTab == tab.id { fullscreenTab = nil }
        let again = tab.crashed.map { Date.now.timeIntervalSince($0) < 60 } ?? false
        tab.crashed = .now
        if again, let url = webView.url ?? tab.site {
            tab.failure = (url, "The page crashed each time it was opened.")
        } else if tab.id == selectedID {
            webView.reload()
        } else {
            tab.sleep()
        }
    }
}

/// Downloads go to ~/Downloads under the name the site gives, numbered when
/// that is taken, and bounce the Downloads stack in the Dock when done.
extension Browser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let destination = Downloads.destination(for: suggestedFilename, in: .downloadsDirectory)
        item(for: download)?.file = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.finish()
        if let file = item.file {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        item(for: download)?.fail()
    }

    private func item(for download: WKDownload) -> Download? {
        downloads.first { $0.task === download }
    }
}

/// What was typed, as somewhere to go: an address as it is, anything else
/// as a Google search.
nonisolated enum Address {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") { return URL(string: text) }

        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let looksLikeAddress = !text.contains(" ") && (host.contains(".") || host.hasPrefix("localhost"))
        if looksLikeAddress, let url = URL(string: (host.hasPrefix("localhost") ? "http://" : "https://") + text) {
            return url
        }

        return search(text)
    }

    static func search(_ text: String) -> URL? {
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// What Google thinks is being searched for, as it would suggest under its
    /// own field; nothing when it can't be reached.
    static func suggestions(for text: String) async -> [String] {
        var request = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        request.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "q", value: text),
        ]
        // ["query", ["suggestion", …], …]
        guard let (data, _) = try? await URLSession.shared.data(from: request.url!),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [Any],
              reply.count > 1, let suggestions = reply[1] as? [String]
        else { return [] }
        return suggestions
    }
}
