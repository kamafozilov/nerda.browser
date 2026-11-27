import Foundation
import Testing
import WebKit
@testable import Nerda

/// Leaving a tab whose video is about to float: the tab list moves on at
/// once, and the page area keeps the page left in sight until WebKit says
/// its video floats, or `Browser.floatingWait` passes. WebKit's word is
/// given here as WebKit gives it, to the browser; nothing floats, and
/// whether a leave floats is the test's to say (`Browser.floatsOnLeaving`).
@MainActor
struct KeptInSightTests {
    /// The record's clock, moved on by the test.
    @MainActor private final class Clock {
        var now: TimeInterval = 1000
    }

    /// A browser with Auto Picture-in-Picture on in settings of its own,
    /// two tabs, `a` on screen, and `a`'s video taken to float when left.
    @MainActor private struct Setup {
        let browser: Browser
        let recorder: Recorder
        let clock: Clock
        let a: Nerda.Tab
        let b: Nerda.Tab
        let settings: UserDefaults
        let suite: String

        func webKitSays(_ tab: Nerda.Tab, floating: Bool) {
            browser.webView(tab.webView, hasVideoInPictureInPictureDidChange: floating)
        }

        func timed(_ kind: Recorder.Kind) -> [Double] {
            recorder.timings().filter { $0.kind == kind }.map { ($0.seconds * 1000).rounded() }
        }

        func close() { settings.removePersistentDomain(forName: suite) }
    }

    private func setup(floats: @escaping (Nerda.Tab) -> Bool) throws -> Setup {
        let suite = "dev.nerda.tests.kept.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(true, forKey: PictureInPicture.key)
        let clock = Clock()
        let recorder = Recorder(clock: { clock.now })
        let browser = Browser(dataStore: .nonPersistent())
        browser.recorder = recorder
        browser.pictureInPictureSettings = settings
        let b = browser.open(URL(string: "about:blank")!)
        let a = browser.open(URL(string: "about:blank")!)
        browser.select(a.id)
        browser.floatsOnLeaving = floats
        return Setup(browser: browser, recorder: recorder, clock: clock, a: a, b: b, settings: settings, suite: suite)
    }

    @Test func theLeftPageStaysInSightUntilItsVideoFloats() throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        setup.browser.select(setup.b.id)
        #expect(setup.browser.selected === setup.b)
        #expect(setup.browser.inSight === setup.a)
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.browser.inSight === setup.b)
    }

    /// WebKit never says: the new page shows once the wait has passed.
    @Test func withNoWordTheNewPageShowsAfterTheWait() async throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        let left = ContinuousClock.now
        setup.browser.select(setup.b.id)
        #expect(setup.browser.selected === setup.b)
        #expect(setup.browser.inSight === setup.a)
        try await waitFor("The new page never showed") { setup.browser.inSight === setup.b }
        #expect(ContinuousClock.now - left >= .seconds(Browser.floatingWait))
    }

    /// A tab left with nothing to float: the new page shows with the tab
    /// list, in the same pass.
    @Test func nothingToFloatShowsTheNewPageAtOnce() throws {
        let setup = try self.setup { _ in false }
        defer { setup.close() }
        setup.browser.select(setup.b.id)
        #expect(setup.browser.inSight === setup.b)
    }

    /// With Auto Picture-in-Picture off nothing floats, and nothing waits.
    @Test func withTheSettingOffNothingWaits() throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        setup.settings.set(false, forKey: PictureInPicture.key)
        setup.browser.select(setup.b.id)
        #expect(setup.browser.inSight === setup.b)
    }

    /// Back on the tab kept in sight before its video floats: it is shown,
    /// and nothing is kept any more.
    @Test func comingBackAtOnceShowsTheTabLeft() throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        setup.browser.select(setup.b.id)
        setup.browser.select(setup.a.id)
        #expect(setup.browser.inSight === setup.a)
        #expect(setup.browser.keptInSight == nil)
    }

    /// On to a third tab while the first is kept: the first stays kept,
    /// the second's page is never shown, and the third's shows on the word.
    @Test func aSecondSwitchKeepsTheFirstPage() throws {
        var setup: Setup!
        setup = try self.setup { _ in true }
        defer { setup.close() }
        let c = setup.browser.open(URL(string: "about:blank")!, inBackground: true)
        setup.browser.select(setup.b.id)
        setup.browser.select(c.id)
        #expect(setup.browser.selected === c)
        #expect(setup.browser.inSight === setup.a)
        setup.webKitSays(setup.b, floating: true)
        #expect(setup.browser.inSight === setup.a)
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.browser.inSight === c)
    }

    /// The tab kept in sight closed: the one selected shows.
    @Test func closingTheTabKeptShowsTheSelected() throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        setup.browser.select(setup.b.id)
        setup.browser.close(setup.a.id)
        #expect(setup.browser.inSight === setup.b)
    }

    /// The page kept in sight ending (its process gone): the one selected shows.
    @Test func thePageKeptEndingShowsTheSelected() throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        setup.browser.select(setup.b.id)
        setup.browser.pageEnded(setup.a.webView, reason: .crash)
        #expect(setup.browser.inSight === setup.b)
    }

    /// The tab switch is timed to the new page shown, the floating as a
    /// kind of its own; while the page left is kept, no switch is timed.
    @Test func theSwitchIsTimedWhenTheNewPageShows() async throws {
        var setup: Setup!
        setup = try self.setup { $0 === setup.a }
        defer { setup.close() }
        // Only WebKit's word ends the keep here: the main loop may be slow
        // to sleep three times on a busy Mac.
        setup.browser.floatingWaitHere = 3600
        // The opening and selecting of the setup settled first.
        try await waitFor("The setup never settled") { setup.recorder.timings().count >= 2 }
        let before = setup.timed(.tabSwitch).count
        setup.browser.select(setup.b.id)
        setup.clock.now += 0.1
        // The main loop goes to sleep, more than once, with the page kept.
        let asleep = Self.mainLoopSleeps()
        try await waitFor("The main loop never slept") { asleep() >= 3 }
        #expect(setup.timed(.tabSwitch).count == before)
        setup.clock.now += 0.05
        setup.webKitSays(setup.a, floating: true)
        try await waitFor("The switch was never timed") { setup.timed(.tabSwitch).count > before }
        #expect(setup.timed(.tabSwitch).last == 150)
        #expect(setup.timed(.floating) == [150])
    }

    /// Counts the main loop going to sleep from now on.
    private static func mainLoopSleeps() -> () -> Int {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            count.value += 1
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        return {
            if count.value >= 3 { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            return count.value
        }
    }
}
