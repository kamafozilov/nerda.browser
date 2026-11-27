import AppKit
import Testing
import WebKit
@testable import Nerda

/// A browser with a data store of its own, Low Power Mode off for it
/// whatever the Mac's: its pages out of sight run (`Tab.hiddenPolicy`).
/// In the mode they would be suspended, and a test waiting on a hidden
/// page's timer or event would pass or fail by the Mac's setting.
@MainActor
func browserRunningOutOfSight() -> Browser {
    let browser = Browser(dataStore: .nonPersistent())
    LowPowerMode.force(false, for: browser.dataStore)
    return browser
}

/// A page in sight, as Nerda in use has one on screen, for as long as it
/// is kept: a bare page of a data store of its own in a plain window off
/// every screen, ordered in behind the rest, hearing nothing of being
/// covered. WebKit runs its network process, one for every page of the
/// run, as busy as the pages it serves: with none of them in sight, at the
/// Mac's background priority, so what hidden pages send and hear comes
/// as late as a busy Mac leaves it, seconds on end, and with one in sight
/// on time. Whether a page is in sight would otherwise be whatever the
/// tests running beside have open. A test that times hidden pages by what
/// reaches its server keeps one.
@MainActor
final class PageInSight {
    private let window: NSWindow
    private let page: WKWebView

    init() async throws {
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        page.hearsWindowCovered(false)
        window.contentView = page
        window.orderBack(nil)
        page.loadHTMLString("<p>In sight</p>", baseURL: nil)
        // In sight, by WebKit's own account (`_webProcessState`, 1 for in the
        // foreground): its network process with it.
        try await waitFor("The page never came in sight") {
            !page.isLoading && page.value(forKey: "_webProcessState") as? Int == 1
        }
    }

    isolated deinit { window.close() }
}
