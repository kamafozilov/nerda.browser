import Foundation
import Testing
import WebKit
@testable import Nerda

/// Until something is typed, picked or filled in, a page's clicks don't
/// look through its boxes; the first edit, the page's own or Nerda's, and
/// they do, as before.
@MainActor @Test func clicksLookThroughBoxesOnlyOnceSomethingIsFilledIn() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    Passwords.install(in: configuration.userContentController)
    let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    page.loadHTMLString("<form><input id=name><input id=secret type=password></form><button>Go</button>",
                        baseURL: URL(string: "https://shop.test/")!)
    for _ in 0..<300 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(100))
    let edited = "return window.nerdaPasswordsEarly?.edited"
    #expect(try await page.callAsyncJavaScript(edited, contentWorld: Passwords.world) as? Bool == false)
    _ = try await page.callAsyncJavaScript("""
        const box = document.getElementById('name');
        box.value = 'jane';
        box.dispatchEvent(new InputEvent('input', { bubbles: true }));
        """, contentWorld: .page)
    #expect(try await page.callAsyncJavaScript(edited, contentWorld: Passwords.world) as? Bool == true)
}
