import Foundation
import Testing
import WebKit
@testable import Nerda

/// A regular (on disk) data store of the test's own, so no other test's
/// tabs take its spare, kept with a spare page from now on. `body` runs
/// once the spare is there; the store and its spare go afterwards.
@MainActor
private func withSpare(_ body: (WKWebsiteDataStore, Browser) async throws -> Void) async throws {
    let id = UUID()
    var browser: Browser? = Browser(dataStore: WKWebsiteDataStore(forIdentifier: id))
    let store = browser!.dataStore
    SparePages.keep(for: store, in: 0)
    do {
        // Running already: its process started before it has anything to load.
        try await waitFor("A spare running", timeout: .seconds(10)) {
            SparePages.page(for: store).flatMap(Processes.pid) != nil
        }
        try await body(store, browser!)
    } catch {
        SparePages.drop(for: store)
        throw error
    }
    SparePages.drop(for: store)
    browser?.closeAll()
    browser = nil
    try? await WKWebsiteDataStore.remove(forIdentifier: id)
}

/// One at a time: Low Power Mode, and the spares it lets go, are every store's.
@Suite(.serialized) @MainActor
struct SparePageTests {
    /// A link opened in a new tab is loaded in the spare page, already running,
    /// and another spare is made after it.
    @Test func aLinkOpenedInANewTabTakesTheSpare() async throws {
        try await withSpare { store, browser in
            let spare = try #require(SparePages.page(for: store))
            let tab = browser.open(URL(string: "about:blank")!, inBackground: true)
            #expect(tab.page === spare)
            #expect(SparePages.page(for: store) == nil)
            try await waitFor("Another spare", timeout: .seconds(10)) { SparePages.page(for: store) != nil }
            #expect(SparePages.page(for: store) !== spare)
        }
    }

    /// ⌘T's tab, sent somewhere, loads in the spare too.
    @Test func aNewTabTakesTheSpare() async throws {
        try await withSpare { store, browser in
            let spare = try #require(SparePages.page(for: store))
            browser.newTab()
            let tab = try #require(browser.selected)
            tab.go(to: URL(string: "about:blank")!)
            #expect(tab.page === spare)
        }
    }

    /// A sleeping tab shown again wakes in the spare, its process already running.
    @Test func aSleepingTabWakesInTheSpare() async throws {
        try await withSpare { store, browser in
            let tab = Nerda.Tab(waitingFor: URL(string: "about:blank")!)
            browser.add(tab, inBackground: true)
            let spare = try #require(SparePages.page(for: store))
            browser.select(tab.id)
            #expect(tab.webView === spare)
        }
    }

    /// An incognito window's store, in memory, keeps no spare: nothing of it
    /// is to outlast the window.
    @Test func incognitoKeepsNoSpare() async throws {
        let browser = Browser(dataStore: .nonPersistent())
        SparePages.keep(for: browser.dataStore, in: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(SparePages.page(for: browser.dataStore) == nil)
    }

    /// In Low Power Mode no page is kept running for nobody: the spare goes as
    /// the mode comes on, none is made while it is, and one comes back after.
    @Test func lowPowerModeKeepsNoSpare() async throws {
        try await withSpare { store, browser in
            defer { LowPowerMode.forced = nil; LowPowerMode.changed() }
            LowPowerMode.forced = true
            LowPowerMode.changed()
            #expect(SparePages.page(for: store) == nil)
            SparePages.keep(for: store, in: 0)
            try await Task.sleep(for: .milliseconds(300))
            #expect(SparePages.page(for: store) == nil)
            LowPowerMode.forced = false
            LowPowerMode.changed()
            try await waitFor("A spare again", timeout: .seconds(10)) { SparePages.page(for: store) != nil }
        }
    }

    /// NERDA_SPARE_PAGE=0: no spare is made, and one already there isn't taken.
    @Test func theSwitchTurnsTheSpareOff() async throws {
        try await withSpare { store, browser in
            let spare = try #require(SparePages.page(for: store))
            Speedups.overrides["SPARE_PAGE"] = false
            let tab = browser.open(URL(string: "about:blank")!)
            Speedups.overrides["SPARE_PAGE"] = nil
            #expect(tab.page !== spare)
        }
        let other = WKWebsiteDataStore(forIdentifier: UUID())
        Speedups.overrides["SPARE_PAGE"] = false
        SparePages.keep(for: other, in: 0)
        Speedups.overrides["SPARE_PAGE"] = nil
        try await Task.sleep(for: .milliseconds(300))
        #expect(SparePages.page(for: other) == nil)
        SparePages.drop(for: other)
    }

    /// The next spare is made only on the run loop's default turns: never in
    /// the middle of a drag or a scroll, which run it in event tracking.
    @Test func noSpareIsMadeDuringADrag() async throws {
        try await withSpare { store, browser in
            _ = browser.open(URL(string: "about:blank")!)
            drag(for: SparePages.renewal + 1)
            #expect(SparePages.page(for: store) == nil)
            try await waitFor("A spare after the drag", timeout: .seconds(10)) { SparePages.page(for: store) != nil }
        }
    }
}

/// A drag lasting `seconds`: the run loop turning in event tracking only,
/// as AppKit has it while the mouse is held.
@MainActor
private func drag(for seconds: TimeInterval) {
    let held = Timer(timeInterval: 0.05, repeats: true) { _ in }
    RunLoop.main.add(held, forMode: .eventTracking)
    let end = Date.now.addingTimeInterval(seconds)
    while Date.now < end { RunLoop.main.run(mode: .eventTracking, before: end) }
    held.invalidate()
}
