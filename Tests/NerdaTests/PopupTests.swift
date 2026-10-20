import Foundation
import Testing
import WebKit
@testable import Nerda

private let somewhere = URL(string: "https://example.com")!

/// A popup, or a link opened in a new tab, hands back to the page that opened it.
@MainActor
@Test func closingAPopupGoesBackToItsOpener() {
    // Its site may open windows: a bare action is no click.
    let browser = Browser(dataStore: .nonPersistent())
    var options = SiteSettings.Options()
    options.allowsPopups = true
    browser.siteSettings.set(options, for: somewhere)
    browser.open(somewhere)
    browser.open(somewhere)
    let opener = browser.tabs[1]
    browser.select(opener.id)
    let popup = browser.webView(opener.webView, createWebViewWith: WKWebViewConfiguration(),
                                for: WKNavigationAction(), windowFeatures: WKWindowFeatures())
    #expect(browser.selected?.webView === popup)

    browser.close(browser.selectedID!)
    #expect(browser.selectedID == opener.id)
}

/// A page opens a window only from a click or a key: one it opens on its
/// own, as it loads, is kept back and told of, and opens once asked for,
/// or by itself on a site allowed pop-ups.
@MainActor
@Test func pagesOpenWindowsOnlyWhenAsked() async throws {
    let browser = Browser(dataStore: .nonPersistent())
    let tab = Tab()
    browser.add(tab)
    let opens = "<script>window.open('https://example.com/popup')</script>"
    tab.webView.loadHTMLString(opens, baseURL: somewhere)
    while tab.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    // A cold page process can take longer than any fixed wait to run the script.
    for _ in 0..<100 where tab.blockedPopups.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(browser.tabs.count == 1)
    #expect(tab.blockedPopups == [URL(string: "https://example.com/popup")!])

    browser.showBlockedPopups(of: tab)
    #expect(browser.tabs.count == 2)
    #expect(browser.selected?.opener == tab.id)
    #expect(tab.blockedPopups.isEmpty)

    // Script the browser runs counts as a click, as Safari's does.
    browser.select(tab.id)
    _ = try? await tab.webView.evaluateJavaScript("window.open('https://example.com/clicked'); 1")
    #expect(browser.tabs.count == 3)
    #expect(tab.blockedPopups.isEmpty)

    var options = SiteSettings.Options()
    options.allowsPopups = true
    browser.siteSettings.set(options, for: somewhere)
    tab.webView.loadHTMLString(opens, baseURL: somewhere)
    while tab.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    for _ in 0..<100 where browser.tabs.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(browser.tabs.count == 4)
}
