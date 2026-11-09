import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

private func offline(at url: URL) -> NSError {
    NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: url])
}

/// A wait for the network ends when the task waiting is cancelled, with the
/// Mac still offline.
@MainActor
@Test func waitingForTheNetworkStopsWhenCancelled() async {
    Online.changed(true)
    let waiting = Task { await Online.back() }
    waiting.cancel()
    await waiting.value
    // Cancelled before it began to wait, too.
    await withTaskGroup(of: Void.self) { group in
        group.cancelAll()
        group.addTask { await Online.back() }
    }
}

/// A tab closed while its page waits for the network goes at once, page and
/// all, though the Mac stays offline: nothing holds it until it is back.
@MainActor
@Test func aTabClosedWhileOfflineIsFreed() async throws {
    // Online already, so only a change would end the wait.
    Online.changed(true)
    let browser = Browser(dataStore: .nonPersistent())
    weak var tab: Nerda.Tab?
    weak var page: WKWebView?
    autoreleasepool {
        let opened = browser.open(URL(string: "about:blank")!)
        let url = URL(string: "https://example.com/")!
        // Twice: one wait at a time, the second taking the first's place.
        browser.webView(opened.webView, didFailProvisionalNavigation: nil, withError: offline(at: url))
        browser.webView(opened.webView, didFailProvisionalNavigation: nil, withError: offline(at: url))
        #expect(opened.failure?.offline == true)
        tab = opened
        page = opened.page
        browser.close(opened.id)
    }
    for _ in 0..<50 where tab != nil || page != nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(tab == nil)
    #expect(page == nil)
}
