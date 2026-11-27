import Foundation
import Testing
import WebKit
@testable import Nerda

/// A browser with no window: one tab on screen and `count` opened behind it,
/// never shown, each with a page, left alone for twenty minutes, so nothing
/// but what a test sets protects them from memory pressure. Its data stays
/// in memory.
@MainActor
private func browser(hidden count: Int) async throws -> (Browser, [Nerda.Tab]) {
    let browser = Browser(dataStore: .nonPersistent())
    browser.open(URL(string: "about:blank")!)
    let hidden = (0..<count).map { _ in browser.open(URL(string: "about:blank")!, inBackground: true) }
    try await waitFor("Pages made") { browser.tabs.allSatisfy { !$0.isAsleep && !$0.webView.isLoading } }
    for tab in hidden { tab.lastSeen = .now.addingTimeInterval(-20 * 60) }
    return (browser, hidden)
}

/// The coordinator a test drives in place of the system, its own, so other
/// tests' windows are left alone.
@MainActor
private func coordinator(for browsers: Browser...) -> SleepCoordinator {
    let coordinator = SleepCoordinator(watchingSystem: false)
    for browser in browsers { coordinator.register(browser) }
    return coordinator
}

/// A memory warning puts no tab to sleep, hidden or pinned, however long
/// unseen: a short spike costs no reloads.
@MainActor
@Test func aMemoryWarningPutsNoTabToSleep() async throws {
    let (browser, hidden) = try await browser(hidden: 3)
    hidden[0].isPinned = true
    let coordinator = coordinator(for: browser)
    coordinator.pressure(.warning)
    try await Task.sleep(for: .milliseconds(500))
    #expect(browser.tabs.allSatisfy { !$0.isAsleep })
    coordinator.pressure(.normal)
}

/// A page that holds on to `megabytes` of memory, written to so it counts.
@MainActor
private func weigh(_ tab: Nerda.Tab, megabytes: Int) async throws {
    let html = "<script>window.kept = new Uint8Array(\(megabytes) << 20).fill(7)</script>"
    tab.webView.loadHTMLString(html, baseURL: nil)
    try await waitFor("Memory taken", timeout: .seconds(10)) { (tab.memory ?? 0) > UInt64(megabytes) << 20 }
}

/// Critical pressure puts the heaviest tab that may sleep to sleep first,
/// and only that one until the next look.
@MainActor
@Test func criticalPressureSleepsTheHeaviestTabFirst() async throws {
    let (browser, hidden) = try await browser(hidden: 3)
    try await weigh(hidden[1], megabytes: 300)
    #expect(Set(hidden.compactMap(\.pid)).count == 3)
    let coordinator = coordinator(for: browser)
    coordinator.lookEvery = .seconds(60)
    defer { coordinator.pressure(.normal) }

    coordinator.pressure(.critical)
    try await waitFor("Heaviest asleep") { hidden[1].isAsleep }
    try await Task.sleep(for: .milliseconds(500))
    #expect(!hidden[0].isAsleep && !hidden[2].isAsleep)
    #expect(browser.selected?.isAsleep == false)
}

/// While pressure stays critical, one more tab sleeps each look, heaviest
/// first; once it ends, no more do.
@MainActor
@Test func criticalPressureSleepsOneTabAtATimeUntilItEnds() async throws {
    let (browser, hidden) = try await browser(hidden: 3)
    try await weigh(hidden[2], megabytes: 300)
    try await weigh(hidden[0], megabytes: 150)
    let coordinator = coordinator(for: browser)
    coordinator.lookEvery = .milliseconds(700)
    defer { coordinator.pressure(.normal) }

    coordinator.pressure(.critical)
    try await waitFor("Heaviest asleep") { hidden[2].isAsleep }
    #expect(!hidden[0].isAsleep)
    try await waitFor("Next heaviest asleep") { hidden[0].isAsleep }
    #expect(!hidden[1].isAsleep)
    coordinator.pressure(.normal)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(!hidden[1].isAsleep)
}

/// Pressure never takes the tab on screen, the last five tabs used, one seen
/// in the last ten minutes, one heard in the last minute or one with
/// changes not sent, nor a pinned tab.
@MainActor
@Test func criticalPressureLeavesProtectedTabsAwake() async throws {
    let (browser, hidden) = try await browser(hidden: 11)
    let front = browser.selected!
    for tab in hidden[0...5] { browser.select(tab.id) }
    browser.select(front.id)
    for tab in hidden[0...5] { tab.lastSeen = .now.addingTimeInterval(-20 * 60) }
    hidden[6].lastSeen = .now.addingTimeInterval(-5 * 60)
    hidden[7].lastHeard = .now.addingTimeInterval(-30)
    hidden[8].hasUnsavedWork = true
    hidden[9].isPinned = true
    let coordinator = coordinator(for: browser)
    coordinator.lookEvery = .milliseconds(200)
    defer { coordinator.pressure(.normal) }

    coordinator.pressure(.critical)
    // The sixth tab back is no longer one of the last five.
    let free = [hidden[0], hidden[10]]
    try await waitFor("Unprotected tabs asleep") { free.allSatisfy(\.isAsleep) }
    try await Task.sleep(for: .seconds(1))
    #expect(!front.isAsleep)
    for (n, tab) in hidden.enumerated() where !free.contains(where: { $0 === tab }) {
        #expect(!tab.isAsleep, "Tab \(n) is protected")
    }
}

/// A tab gone to more than fifteen times is one you keep coming back to:
/// the idle timer leaves it awake, however long unseen, and still puts
/// the others to sleep.
@MainActor
@Test func theIdleTimerLeavesATabSwitchedToOftenAwake() async throws {
    let (browser, hidden) = try await browser(hidden: 2)
    let front = browser.selected!
    for _ in 0..<16 {
        browser.select(hidden[0].id)
        browser.select(front.id)
    }
    for tab in hidden { tab.lastSeen = .now.addingTimeInterval(-5 * 60 * 60) }

    coordinator(for: browser).check()
    try await waitFor("Unvisited tab asleep") { hidden[1].isAsleep }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!hidden[0].isAsleep)
}

/// Fifteen times is not more than fifteen: the timer takes it.
@MainActor
@Test func theIdleTimerTakesATabSwitchedToFifteenTimes() async throws {
    let (browser, hidden) = try await browser(hidden: 1)
    let front = browser.selected!
    for _ in 0..<15 {
        browser.select(hidden[0].id)
        browser.select(front.id)
    }
    hidden[0].lastSeen = .now.addingTimeInterval(-5 * 60 * 60)

    coordinator(for: browser).check()
    try await waitFor("Tab asleep") { hidden[0].isAsleep }
}

/// With the pressure policy turned off for the run (NERDA_PRESSURE_POLICY=0),
/// a warning puts every tab out of sight to sleep at once, as before. The
/// switch is read as pressure comes, so it is set only around that call:
/// tests run side by side.
@MainActor
@Test func withThePressurePolicyOffAWarningSleepsEveryHiddenTab() async throws {
    let (browser, hidden) = try await browser(hidden: 3)
    hidden[0].lastSeen = .now
    let coordinator = coordinator(for: browser)
    Speedups.overrides[.pressurePolicy] = false
    coordinator.pressure(.warning)
    Speedups.overrides[.pressurePolicy] = nil
    try await waitFor("Hidden tabs asleep") { hidden.allSatisfy(\.isAsleep) }
    #expect(browser.selected?.isAsleep == false)
}

/// With the pressure policy off, the timer takes a tab however often it
/// was gone to.
@MainActor
@Test func withThePressurePolicyOffTheTimerTakesATabSwitchedToOften() async throws {
    let (browser, hidden) = try await browser(hidden: 1)
    let front = browser.selected!
    for _ in 0..<16 {
        browser.select(hidden[0].id)
        browser.select(front.id)
    }
    hidden[0].lastSeen = .now.addingTimeInterval(-5 * 60 * 60)
    let coordinator = coordinator(for: browser)
    Speedups.overrides[.pressurePolicy] = false
    coordinator.check()
    Speedups.overrides[.pressurePolicy] = nil
    try await waitFor("Revisited tab asleep") { hidden[0].isAsleep }
}

/// Critical pressure looks across every window for the heaviest tab.
@MainActor
@Test func criticalPressureTakesTheHeaviestTabOfAnyWindow() async throws {
    let (first, light) = try await browser(hidden: 1)
    let (second, heavy) = try await browser(hidden: 1)
    try await weigh(heavy[0], megabytes: 300)
    let coordinator = coordinator(for: first, second)
    coordinator.lookEvery = .seconds(60)
    defer { coordinator.pressure(.normal) }

    coordinator.pressure(.critical)
    try await waitFor("Heaviest asleep") { heavy[0].isAsleep }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!light[0].isAsleep)
}

/// The idle timer leaves a tab whose video floats awake, however long
/// unseen, paused or not, and still puts the others to sleep. WebKit's word
/// that it floats is given here as WebKit gives it.
@MainActor
@Test func theIdleTimerLeavesATabWhoseVideoFloatsAwake() async throws {
    let (browser, hidden) = try await browser(hidden: 2)
    browser.webView(hidden[0].webView, hasVideoInPictureInPictureDidChange: true)
    browser.sleepIdleTabs(unseenFor: 0)
    try await waitFor("The other tab asleep") { hidden[1].isAsleep }
    #expect(!hidden[0].isAsleep)
    #expect(hidden[0].isFloating)
}

/// Critical pressure passes over a tab whose video floats, the heaviest
/// though it is, and takes the next one.
@MainActor
@Test func criticalPressureLeavesATabWhoseVideoFloatsAwake() async throws {
    let (browser, hidden) = try await browser(hidden: 2)
    try await weigh(hidden[0], megabytes: 300)
    browser.webView(hidden[0].webView, hasVideoInPictureInPictureDidChange: true)
    let coordinator = coordinator(for: browser)
    coordinator.lookEvery = .seconds(60)
    defer { coordinator.pressure(.normal) }

    coordinator.pressure(.critical)
    try await waitFor("The lighter tab asleep") { hidden[1].isAsleep }
    #expect(!hidden[0].isAsleep)
    #expect(hidden[0].isFloating)
}
