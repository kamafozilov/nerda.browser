import Foundation
import Testing
import WebKit
@testable import Nerda

/// A browser with no window and `count` tabs, each with a page, the last on
/// screen. Its data stays in memory, so tabs are pinned by hand: an
/// incognito window has no pins of its own (`Browser.keepsPins`).
@MainActor
private func browser(tabs count: Int) async throws -> Browser {
    let browser = Browser(dataStore: .nonPersistent())
    for _ in 0..<count { browser.open(URL(string: "about:blank")!) }
    try await waitFor("Pages made") { browser.tabs.allSatisfy { !$0.isAsleep && !$0.webView.isLoading } }
    return browser
}

/// Every window's tabs sleep from one coordinator, which a test drives in
/// place of the system: its own, so other tests' windows are left alone.
@MainActor
private func coordinator(for browsers: Browser...) -> SleepCoordinator {
    let coordinator = SleepCoordinator(watchingSystem: false)
    for browser in browsers { coordinator.register(browser) }
    return coordinator
}

/// A memory warning puts every tab out of sight to sleep at once, in every
/// window, but not the tab on screen nor pinned ones.
@MainActor
@Test func aMemoryWarningSleepsHiddenTabsInEveryWindow() async throws {
    let first = try await browser(tabs: 3)
    let second = try await browser(tabs: 2)
    let pinned = first.tabs.last { $0.id != first.selectedID }!
    pinned.isPinned = true
    let hidden = (first.tabs + second.tabs).filter { !$0.isPinned && $0.id != first.selectedID && $0.id != second.selectedID }
    #expect(hidden.count == 2)

    coordinator(for: first, second).pressure(.warning)
    try await waitFor("Hidden tabs asleep") { hidden.allSatisfy(\.isAsleep) }
    #expect(!pinned.isAsleep)
    #expect(first.selected?.isAsleep == false && second.selected?.isAsleep == false)
}

/// Critical pressure puts pinned tabs out of sight to sleep too, as in Safari.
@MainActor
@Test func criticalPressureSleepsPinnedTabsToo() async throws {
    let browser = try await browser(tabs: 2)
    let pinned = browser.tabs.first { $0.id != browser.selectedID }!
    pinned.isPinned = true

    coordinator(for: browser).pressure(.critical)
    try await waitFor("Pinned tab asleep") { pinned.isAsleep }
    #expect(browser.selected?.isAsleep == false)
}

/// Pressure back to normal puts nothing to sleep.
@MainActor
@Test func normalPressureSleepsNothing() async throws {
    let browser = try await browser(tabs: 2)
    coordinator(for: browser).pressure(.normal)
    try await Task.sleep(for: .milliseconds(300))
    #expect(browser.tabs.allSatisfy { !$0.isAsleep })
}

/// Each minute's check puts to sleep, in every window, the tabs unseen for
/// longer than Settings › Tabs allows (30 minutes unless changed), and
/// leaves the ones seen since.
@MainActor
@Test func theIdleCheckSleepsTabsUnseenTooLongInEveryWindow() async throws {
    let first = try await browser(tabs: 3)
    let second = try await browser(tabs: 2)
    let old = [first.tabs.last!, second.tabs.last!]
    let recent = first.tabs[1]
    for tab in old { tab.lastSeen = .now.addingTimeInterval(-5 * 60 * 60) }
    recent.lastSeen = .now.addingTimeInterval(-60)
    #expect(!(old + [recent]).contains { $0.id == first.selectedID || $0.id == second.selectedID })

    coordinator(for: first, second).check()
    try await waitFor("Old tabs asleep") { old.allSatisfy(\.isAsleep) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!recent.isAsleep)
}

/// A window gone is let go of: the coordinator doesn't keep it.
@MainActor
@Test func theCoordinatorLetsGoOfAClosedWindow() async throws {
    let coordinator = SleepCoordinator(watchingSystem: false)
    weak var gone: Browser?
    autoreleasepool {
        let browser = Browser(dataStore: .nonPersistent())
        coordinator.register(browser)
        gone = browser
    }
    try await waitFor("Browser gone") { gone == nil }
    coordinator.pressure(.critical)
}

/// Low Power Mode reaches the coordinator as it changes, and a test can turn it on.
@MainActor
@Test func lowPowerModeReachesTheCoordinator() {
    defer { LowPowerMode.forced = nil; LowPowerMode.changed() }
    let coordinator = SleepCoordinator(watchingSystem: false)
    LowPowerMode.forced = true
    LowPowerMode.changed()
    #expect(coordinator.lowPower)
    LowPowerMode.forced = false
    LowPowerMode.changed()
    #expect(!coordinator.lowPower)
}
