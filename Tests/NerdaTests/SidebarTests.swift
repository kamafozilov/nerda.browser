import AppKit
import SwiftUI
import Testing
@testable import Nerda

/// A window of the browser's, behind the one in use.
@MainActor
private func window(of browser: Browser) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
    window.orderBack(nil)
    return window
}

/// Every accessibility element under `element`, as VoiceOver walks them.
@MainActor
private func elements(under element: AnyObject) -> [AnyObject] {
    let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
    return children.flatMap { [$0] + elements(under: $0) }
}

private func saved(_ title: String, pinned: Bool = false) -> Session.Tab {
    let url = URL(string: "https://\(title.lowercased()).example/")!
    return Session.Tab(url: url, title: title, state: nil, zoom: 1, pinned: pinned ? true : nil, home: pinned ? url : nil)
}

/// SwiftUI makes its accessibility elements only once something asks for
/// them, as VoiceOver does by setting this on the app.
@MainActor
private func withAccessibility(_ body: () async throws -> Void) async rethrows {
    let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    NSApp.accessibilitySetValue(true, forAttribute: attribute)
    defer { NSApp.accessibilitySetValue(false, forAttribute: attribute) }
    try await body()
}

/// VoiceOver hears each tab by its title, which one is on screen, and can
/// close it, mute it or take a pinned site home, though those buttons show
/// only under the pointer.
@MainActor
@Test func voiceOverTellsTheSelectedTabAndClosesIt() async throws {
    let browser = Browser()
    browser.add([Nerda.Tab(restoring: saved("Home", pinned: true)), Nerda.Tab(restoring: saved("One")),
                 Nerda.Tab(restoring: saved("Two"))])
    let shown = browser.open(URL(string: "data:text/html,<title>Shown</title>")!)
    let window = window(of: browser)
    defer { window.close() }
    try await withAccessibility {
        _ = window.contentView!.accessibilityChildren()
        var all: [AnyObject] = []
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(50))
            all = elements(under: window.contentView!)
            if all.contains(where: { $0.accessibilityLabel?() == "One" }) { break }
        }
        func element(_ label: String) -> AnyObject? { all.first { $0.accessibilityLabel?() == label } }
        func actions(_ label: String) -> [String] { (element(label)?.accessibilityCustomActions?() ?? []).map(\.name) }

        let selected = all.filter { $0.accessibilityRole?() == .button && $0.isAccessibilitySelected?() == true }
        #expect(selected.count == 1)
        #expect(selected.first?.accessibilityLabel?() == shown.title)
        #expect(element("One")?.isAccessibilitySelected?() == false)
        #expect(actions("One").contains("Close Tab"))
        #expect(actions("One").contains("Rename"))
        #expect(actions("Home").contains("Back to Pinned Page"))
        // The address bar's buttons by what they do, without their shortcut.
        #expect((element("Reload") ?? element("Stop"))?.accessibilityRole?() == .button)
        #expect(element("Back")?.accessibilityRole?() == .button)

        let close = element("One")?.accessibilityCustomActions?()?.first { $0.name == "Close Tab" }
        _ = close?.handler?()
        #expect(!browser.tabs.contains { $0.title == "One" })
    }
}

/// ↑ and ↓ in the tab list go one tab up or down, and stop at either end.
@MainActor
@Test func theArrowsGoToTheTabAboveOrBelow() {
    let ids = [UUID(), UUID(), UUID()]
    #expect(Sidebar.tab(after: ids[1], in: ids, by: 1) == ids[2])
    #expect(Sidebar.tab(after: ids[1], in: ids, by: -1) == ids[0])
    #expect(Sidebar.tab(after: ids[0], in: ids, by: -1) == nil)
    #expect(Sidebar.tab(after: ids[2], in: ids, by: 1) == nil)
    #expect(Sidebar.tab(after: ids[1], in: ids, by: 0) == nil)
    #expect(Sidebar.tab(after: UUID(), in: ids, by: 1) == nil)
}

/// A tab put on screen from the list by the keyboard leaves the keyboard
/// in the list, for the next arrow; a click's tab takes it, as before.
@MainActor
@Test func aTabPutOnScreenFromTheKeyboardLeavesItInTheList() async throws {
    let browser = Browser()
    let window = window(of: browser)
    defer { window.close() }
    let a = browser.open(URL(string: "data:text/html,a")!), b = browser.open(URL(string: "data:text/html,b")!)
    try await Task.sleep(for: .milliseconds(500))
    func pageHasKeyboard(_ tab: Nerda.Tab) -> Bool {
        guard let responder = window.firstResponder as? NSView, let page = tab.page else { return false }
        return responder === page || responder.isDescendant(of: page)
    }

    window.makeFirstResponder(nil)
    browser.select(keepingKeyboard: a.id)
    for _ in 0..<100 where browser.keepsKeyboard != nil { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(browser.selectedID == a.id)
    #expect(!pageHasKeyboard(a))
    #expect(browser.keepsKeyboard == nil)

    browser.select(b.id)
    for _ in 0..<50 where !pageHasKeyboard(b) { try await Task.sleep(for: .milliseconds(20)) }
    #expect(pageHasKeyboard(b))
}

/// Links dropped on the tabs open in new tabs where they are let go, in
/// their order, the first on screen.
@MainActor
@Test func droppedLinksOpenWhereTheyAreLetGo() {
    let browser = Browser()
    browser.add([Nerda.Tab(restoring: saved("Home", pinned: true)), Nerda.Tab(restoring: saved("One")),
                 Nerda.Tab(restoring: saved("Two")), Nerda.Tab(restoring: saved("Three"))])
    let first = URL(string: "https://first.example/")!, second = URL(string: "https://second.example/")!
    let opened = browser.open([first, second], at: 1, among: Browser.listed)
    #expect(browser.tabs.map(\.title) == ["Home", "One", opened[0].title, opened[1].title, "Two", "Three"])
    #expect(opened.map(\.site) == [first, second])
    #expect(browser.selectedID == opened[0].id)
}

/// What is dragged comes as its address, a file's by its path, and only
/// what File › Open File… opens is taken.
@MainActor
@Test func aDroppedFileIsTakenByItsPath() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let page = folder.appending(path: "page.html"), archive = folder.appending(path: "files.zip")
    try "<p>Here</p>".write(to: page, atomically: true, encoding: .utf8)
    try Data([0]).write(to: archive)

    let link = await LinkDrop.url(from: NSItemProvider(object: URL(string: "https://dropped.example/")! as NSURL))
    #expect(link == URL(string: "https://dropped.example/"))
    // As the Finder hands one over: by reference.
    let reference = try #require((page as NSURL).fileReferenceURL())
    let file = await LinkDrop.url(from: NSItemProvider(object: reference as NSURL))
    #expect(file?.standardizedFileURL == page.standardizedFileURL)
    #expect(ExternalNavigation.accepts(file!))
    #expect(!ExternalNavigation.accepts(archive))
}
