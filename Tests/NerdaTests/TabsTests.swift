import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Waits up to two seconds for `done`.
@MainActor
private func until(_ done: () -> Bool) async throws {
    for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
}

private func saved(_ host: String, pinned: Bool = false) -> Session.Tab {
    Session.Tab(url: URL(string: "https://\(host)/")!, title: host, state: nil, zoom: 1,
                pinned: pinned ? true : nil, home: nil)
}

/// Restored in one go, the tabs come back as they did one by one: pinned
/// first, each kind in its own order, the one on screen by its place.
@MainActor
@Test func restoredTabsKeepTheirOrder() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    let tabs = [saved("a.test"), saved("p.test", pinned: true), saved("b.test"), saved("q.test", pinned: true)]
    try JSONEncoder().encode(Session(tabs: tabs, selected: 2)).write(to: file)

    let browser = Browser()
    browser.restore(from: file)
    #expect(browser.tabs.map(\.title) == ["p.test", "q.test", "a.test", "b.test"])
    #expect(browser.selectedID == browser.tabs[2].id)
    #expect(browser.tabs.allSatisfy { $0.delegate === browser })

    // More of them later go above the rest, as `add` puts them.
    browser.add([Nerda.Tab(restoring: saved("c.test")), Nerda.Tab(restoring: saved("r.test", pinned: true))])
    #expect(browser.tabs.map(\.title) == ["r.test", "p.test", "q.test", "c.test", "a.test", "b.test"])
}

/// Saved off the main thread, the file is what it always was, and written
/// only when the tabs changed; a save that waits comes after one on its way.
@MainActor
@Test func theSessionIsWrittenInTheBackgroundOnlyWhenItChanged() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "session.json")
    let browser = Browser()
    browser.add([Nerda.Tab(restoring: saved("a.test")), Nerda.Tab(restoring: saved("b.test"))])
    browser.sessionFile = file

    browser.saveSession(waiting: false)
    browser.saveSession()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try Data(contentsOf: file) == (try encoder.encode(browser.session)))

    // Unchanged, nothing is written.
    try FileManager.default.removeItem(at: file)
    browser.saveSession(waiting: false)
    Session.writer.sync {}
    #expect(!FileManager.default.fileExists(atPath: file.path))

    browser.rename(browser.tabs[0].id, to: "Reading")
    browser.saveSession(waiting: false)
    Session.writer.sync {}
    #expect(try JSONDecoder().decode(Session.self, from: Data(contentsOf: file)).tabs.first?.name == "Reading")
}

/// A sleeping tab's picture is kept packed, and comes back as it was.
@MainActor
@Test func aSleepingTabKeepsItsPictureAsItWas() async throws {
    let size = NSSize(width: 52, height: 32)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill(using: .copy)
        return true
    }
    let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let packed = try #require(Nerda.Tab.png(pixels))
    let back = try #require(NSBitmapImageRep(data: packed))
    let original = NSBitmapImageRep(cgImage: pixels)
    #expect(back.pixelsWide == original.pixelsWide && back.pixelsHigh == original.pixelsHigh)
    for (x, y) in [(0, 0), (original.pixelsWide - 1, 0), (0, original.pixelsHigh - 1)] {
        // The same to the last of 255 steps: only the colour profile's rounding differs.
        let colors = [back, original].compactMap { $0.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        let channels = colors.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] }
        #expect(channels.count == 2 && zip(channels[0], channels[1]).allSatisfy { abs($0 - $1) < 1 / 255 })
    }

    let tab = Nerda.Tab(url: URL(string: "about:blank")!)
    tab.sleep(keeping: image)
    try await until { tab.look != nil }
    #expect(tab.look.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width } == pixels.width)
    _ = tab.webView
    #expect(tab.look == nil)
}

/// What had the keyboard, taken out of the page and put back, has it
/// again; what was let go of first doesn't.
@MainActor
@Test func anElementMovedInThePageKeepsTheKeyboard() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(Nerda.Tab.keepFocus)
    let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    page.loadHTMLString("<input id=field><div id=elsewhere></div>", baseURL: nil)
    try await until { !page.isLoading && page.url != nil }
    try await Task.sleep(for: .milliseconds(100))

    let move = """
        const field = document.getElementById('field');
        field.remove();
        await new Promise(done => setTimeout(done, 0));
        document.getElementById('elsewhere').append(field);
        await new Promise(done => setTimeout(done, 0));
        return document.activeElement === field;
        """
    _ = try await page.callAsyncJavaScript("document.getElementById('field').focus()", contentWorld: .page)
    #expect(try await page.callAsyncJavaScript(move, contentWorld: .page) as? Bool == true)

    _ = try await page.callAsyncJavaScript("document.getElementById('field').blur()", contentWorld: .page)
    #expect(try await page.callAsyncJavaScript(move, contentWorld: .page) as? Bool == false)
}

/// A page out of sight that asks something waits for its tab to come on
/// screen, and is answered then, not before.
@MainActor
@Test func aHiddenTabsQuestionWaitsForItsTab() async throws {
    let browser = Browser()
    browser.open(URL(string: "about:blank")!)
    let asking = browser.open(URL(string: "data:text/html,<title>waiting</title>")!, inBackground: true)
    try await until { asking.title == "waiting" }
    asking.webView.evaluateJavaScript("setTimeout(() => { confirm('Leave?'); document.title = 'answered'; })", completionHandler: nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(asking.title == "waiting")

    // With no window to show it in, the question is let go once its tab is on screen.
    browser.select(asking.id)
    try await until { asking.title == "answered" }
    #expect(asking.title == "answered")
}
