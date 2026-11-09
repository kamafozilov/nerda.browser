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
