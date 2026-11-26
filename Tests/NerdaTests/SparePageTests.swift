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
    // Off, whatever the Mac's: in Low Power Mode no spare is kept.
    LowPowerMode.force(false, for: store)
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

/// One at a time, each with a store of its own and Low Power Mode set for
/// that store only (`LowPowerMode.force`), so no other test's spare goes.
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
            LowPowerMode.force(true, for: store)
            LowPowerMode.changed()
            #expect(SparePages.page(for: store) == nil)
            SparePages.keep(for: store, in: 0)
            try await Task.sleep(for: .milliseconds(300))
            #expect(SparePages.page(for: store) == nil)
            LowPowerMode.force(false, for: store)
            LowPowerMode.changed()
            try await waitFor("A spare again", timeout: .seconds(10)) { SparePages.page(for: store) != nil }
        }
    }

    /// Under critical memory pressure no page is kept running for nobody:
    /// the spare goes, none is made while it lasts, and one comes back after.
    @Test func criticalMemoryPressureKeepsNoSpare() async throws {
        try await withSpare { store, browser in
            let coordinator = SleepCoordinator(watchingSystem: false)
            coordinator.register(browser)
            coordinator.pressure(.critical)
            #expect(SparePages.page(for: store) == nil)
            SparePages.keep(for: store, in: 0)
            try await Task.sleep(for: .milliseconds(300))
            #expect(SparePages.page(for: store) == nil)
            coordinator.pressure(.normal)
            try await waitFor("A spare again", timeout: .seconds(10)) { SparePages.page(for: store) != nil }
        }
    }

    /// NERDA_SPARE_PAGE=0: no spare is made, and one already there isn't taken.
    @Test func theSwitchTurnsTheSpareOff() async throws {
        try await withSpare { store, browser in
            let spare = try #require(SparePages.page(for: store))
            Speedups.overrides[.sparePage] = false
            let tab = browser.open(URL(string: "about:blank")!)
            Speedups.overrides[.sparePage] = nil
            #expect(tab.page !== spare)
        }
        let other = WKWebsiteDataStore(forIdentifier: UUID())
        Speedups.overrides[.sparePage] = false
        SparePages.keep(for: other, in: 0)
        Speedups.overrides[.sparePage] = nil
        try await Task.sleep(for: .milliseconds(300))
        #expect(SparePages.page(for: other) == nil)
        SparePages.drop(for: other)
    }

    /// The next spare is made only on the run loop's default turns: never in
    /// the middle of a drag or a scroll, which run it in event tracking.
    @Test func noSpareIsMadeDuringADrag() async throws {
        try await withSpare { store, browser in
            _ = browser.open(URL(string: "about:blank")!)
            let madeMeanwhile = await drag(for: SparePages.renewal + 1) { SparePages.page(for: store) != nil }
            #expect(!madeMeanwhile)
            try await waitFor("A spare after the drag", timeout: .seconds(10)) { SparePages.page(for: store) != nil }
        }
    }
}

/// A drag lasting `seconds`: the run loop turning in event tracking only,
/// as AppKit has it while the mouse is held, and `then` as it ends, before
/// the loop turns in its default mode again. Run from the run loop, as
/// AppKit runs one from an event, rather than from this test's turn of the
/// main queue: the queue then goes on in event tracking, as it does in a
/// real drag, and the other tests on the main thread with it.
@MainActor
private func drag<T: Sendable>(for seconds: TimeInterval, then: @escaping @MainActor () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                let held = Timer(timeInterval: 0.05, repeats: true) { _ in }
                RunLoop.main.add(held, forMode: .eventTracking)
                let end = Date.now.addingTimeInterval(seconds)
                while Date.now < end { RunLoop.main.run(mode: .eventTracking, before: end) }
                held.invalidate()
                done.resume(returning: then())
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
