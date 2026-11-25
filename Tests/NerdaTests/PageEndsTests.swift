import Foundation
import Testing
import WebKit
@testable import Nerda

private let somewhere = URL(string: "https://example.com")!

/// Ends the pages of `tabs` in one moment, each once it has loaded (a page
/// whose process is gone commits nothing more), `reason` as WebKit's private
/// callback tells it, and waits for that moment to be over.
@MainActor
private func end(_ tabs: [Nerda.Tab], in browser: Browser, reason: PageEnd? = nil) async throws {
    for tab in tabs {
        try await waitFor { tab.webView.isLoading == false }
    }
    for tab in tabs {
        if let reason {
            browser.webView(tab.webView, processEndedFor: reason.rawValue)
        } else {
            browser.webViewWebContentProcessDidTerminate(tab.webView)
        }
    }
    try await waitFor { !browser.pageEnds.gathering }
}

/// Pages that end together went for something they share, a WebKit process
/// or the Mac's memory: none of them is a page that keeps crashing, however
/// often that happens, and the one on screen is loaded again each time.
@MainActor
@Test func pagesEndingTogetherAreNotCrashing() async throws {
    let browser = Browser(dataStore: .nonPersistent())
    let hidden = browser.open(somewhere)
    let shown = browser.open(somewhere)
    #expect(browser.selectedID == shown.id)
    for _ in 0..<4 {
        try await end([shown, hidden], in: browser)
        #expect(shown.failure == nil)
        #expect(hidden.failure == nil)
        #expect(hidden.isAsleep)
    }
}

/// The same holds across windows: pages of two windows ending together
/// went for one cause, which no window alone could tell.
@MainActor
@Test func pagesOfTwoWindowsEndingTogetherAreNotCrashing() async throws {
    let one = Browser(dataStore: .nonPersistent())
    let two = Browser(dataStore: .nonPersistent())
    let a = one.open(somewhere)
    let b = two.open(somewhere)
    for _ in 0..<3 {
        for tab in [a, b] { try await waitFor { tab.webView.isLoading == false } }
        one.webViewWebContentProcessDidTerminate(a.webView)
        two.webViewWebContentProcessDidTerminate(b.webView)
        try await waitFor { !one.pageEnds.gathering && !two.pageEnds.gathering }
    }
    #expect(a.failure == nil)
    #expect(b.failure == nil)
}

/// Why a page ended is kept, and a page that keeps running out of memory
/// says that, not that it crashed.
@MainActor
@Test func aPageThatKeepsRunningOutOfMemorySaysSo() async throws {
    let browser = Browser(dataStore: .nonPersistent())
    // Its own, so no other test's page ends in the same moment.
    browser.pageEnds = PageEnds()
    let tab = browser.open(somewhere)
    try await end([tab], in: browser, reason: .memory)
    #expect(tab.ended == .memory)
    try await end([tab], in: browser, reason: .memory)
    #expect(tab.failure == nil)
    try await end([tab], in: browser, reason: .memory)
    #expect(tab.failure?.message == "The page ran out of memory each time it was opened.")
}

/// A page's process that was asked to end, by WebKit swapping it or by
/// Nerda ending a page that stopped answering, did not crash: it is loaded
/// again, or sleeps out of sight, and never counts.
@MainActor
@Test func pagesEndedOnPurposeAreNotCrashing() async throws {
    let browser = Browser(dataStore: .nonPersistent())
    let hidden = browser.open(somewhere)
    let tab = browser.open(somewhere)
    for _ in 0..<3 {
        try await end([tab], in: browser, reason: .requested)
    }
    #expect(tab.failure == nil)

    for _ in 0..<3 {
        tab.endingOnPurpose = true
        try await end([tab], in: browser, reason: .crash)
        #expect(!tab.endingOnPurpose)
    }
    #expect(tab.failure == nil)

    hidden.endingOnPurpose = true
    browser.webView(hidden.webView, processEndedFor: PageEnd.crash.rawValue)
    #expect(hidden.isAsleep)
    #expect(!hidden.endingOnPurpose)
}
