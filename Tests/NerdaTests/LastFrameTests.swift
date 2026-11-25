import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Nerda

/// Switching back to a tab shows its page's last frame until the page draws,
/// and only while the page would look exactly as it did (LastFrame.swift).
/// Serialized: one test turns the switch off for all of Nerda.
@Suite(.serialized)
@MainActor
struct LastFrameTests {
    /// A tall page, so it can scroll.
    private static let page = "<body style='height:3000px;margin:0;background:#3a6'><p>Page</p>"

    /// A browser in a window behind the others, with `a` shown first, then
    /// `b` in front of it: `a`'s last frame kept, ready to come back to.
    private func twoTabs() async throws -> (Browser, NSWindow, Nerda.Tab, Nerda.Tab) {
        let browser = Browser(dataStore: .nonPersistent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
        window.orderBack(nil)
        let a = browser.open(URL(string: "about:blank")!)
        a.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://a.example/")!)
        try await waitFor("A on screen") { a.webView.window != nil && !a.webView.isLoading && a.webView.url != nil }
        try await Task.sleep(for: .milliseconds(200))
        let b = browser.open(URL(string: "about:blank")!)
        b.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://b.example/")!)
        try await waitFor("A's last frame kept") { a.webView.keepsLastFrame }
        return (browser, window, a, b)
    }

    @Test func switchingBackToAnUnchangedTabShowsItsLastFrame() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        browser.select(a.id)
        try await waitFor("A back") { a.webView.lastArrival != nil }
        #expect(a.webView.lastArrival == .lastFrame)
    }

    @Test func aResizedWindowGetsTheLivePage() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        let size = a.webView.bounds.size
        window.setContentSize(NSSize(width: 1000, height: 700))
        try await waitFor("A resized") { a.webView.bounds.size != size }
        browser.select(a.id)
        try await waitFor("A back") { a.webView.lastArrival != nil }
        #expect(a.webView.lastArrival == .live(because: "size"))
    }

    @Test func aZoomedPageGetsTheLivePage() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        a.webView.pageZoom = 1.25
        browser.select(a.id)
        try await waitFor("A back") { a.webView.lastArrival != nil }
        #expect(a.webView.lastArrival == .live(because: "zoom"))
    }

    @Test func anotherAppearanceGetsTheLivePage() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        let dark = a.webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        browser.select(a.id)
        try await waitFor("A back") { a.webView.lastArrival != nil }
        #expect(a.webView.lastArrival == .live(because: "appearance"))
    }

    @Test func aPageThatWentElsewhereGetsTheLivePage() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        a.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://elsewhere.example/")!)
        try await waitFor("A elsewhere") { a.webView.url?.host == "elsewhere.example" }
        browser.select(a.id)
        try await waitFor("A back") { a.webView.lastArrival != nil }
        #expect(a.webView.lastArrival == .live(because: "address"))
    }

    /// A page that scrolled itself out of sight: its frame, if put up at
    /// all, goes as soon as the page says where it is.
    @Test func aPageScrolledOutOfSightGetsTheLivePage() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        _ = try await a.webView.evaluateJavaScript("scrollTo(0, 800); scrollY")
        browser.select(a.id)
        try await waitFor("A live") { a.webView.lastArrival == .live(because: "scroll") }
        #expect(!a.webView.showsLastFrame)
    }

    /// A tab that slept comes back in a new page: its hover card's picture
    /// never stands in for its last frame.
    @Test func aWokenTabHasNoLastFrame() async throws {
        let (browser, window, a, _) = try await twoTabs()
        defer { window.close() }
        a.sleep(keeping: NSImage(size: NSSize(width: 10, height: 10)))
        try await waitFor("A asleep") { a.isAsleep }
        browser.select(a.id)
        try await waitFor("A back") { a.page?.lastArrival != nil }
        #expect(a.page?.lastArrival == .live(because: "none"))
    }

    @Test func theSwitchTurnsItOff() async throws {
        Speedups.overrides["LAST_FRAME"] = false
        defer { Speedups.overrides["LAST_FRAME"] = nil }
        let browser = Browser(dataStore: .nonPersistent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
        window.orderBack(nil)
        defer { window.close() }
        let a = browser.open(URL(string: "about:blank")!)
        a.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://a.example/")!)
        try await waitFor("A on screen") { a.webView.window != nil && !a.webView.isLoading && a.webView.url != nil }
        browser.open(URL(string: "about:blank")!)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!a.webView.keepsLastFrame)
        browser.select(a.id)
        try await waitFor("A back") { a.webView.lastArrival != nil }
        #expect(a.webView.lastArrival == .live(because: "off"))
    }
}
