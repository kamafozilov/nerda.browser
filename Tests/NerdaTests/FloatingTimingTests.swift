import Foundation
import Testing
import WebKit
@testable import Nerda

/// Floating and landing in the record (Recorder), on the record's fake
/// clock: the owner leaving a tab whose video Nerda asks to float, and
/// coming back to it, timed until WebKit says the video floats or has
/// landed (`_webView:hasVideoInPictureInPictureDidChange:`). WebKit's word
/// is given here as WebKit gives it, to the browser; nothing floats. Each
/// tab's page has a video the owner chose, as its frame would tell it.
@MainActor
struct FloatingTimingTests {
    /// The record's clock, moved on by the test.
    @MainActor private final class Clock {
        var now: TimeInterval = 1000
    }

    /// A browser with Auto Picture-in-Picture on in settings of its own,
    /// its record on `clock`, and two tabs, the second on screen.
    @MainActor private struct Setup {
        let browser: Browser
        let recorder: Recorder
        let clock: Clock
        let a: Nerda.Tab
        let b: Nerda.Tab
        let settings: UserDefaults
        let suite: String

        /// WebKit's word that `tab`'s page has a video floating, or not.
        func webKitSays(_ tab: Nerda.Tab, floating: Bool) {
            browser.webView(tab.webView, hasVideoInPictureInPictureDidChange: floating)
        }

        func timed(_ kind: Recorder.Kind) -> [TimeInterval] {
            recorder.timings().filter { $0.kind == kind }.map(\.seconds)
        }

        func close() { settings.removePersistentDomain(forName: suite) }
    }

    private func setup(forAgents: Bool = false, on: Bool = true) throws -> Setup {
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(on, forKey: PictureInPicture.key)
        let clock = Clock()
        let recorder = Recorder(clock: { clock.now })
        let browser = Browser(dataStore: .nonPersistent(), forAgents: forAgents)
        browser.recorder = recorder
        browser.pictureInPictureSettings = settings
        browser.videoClock = { clock.now }
        let a = browser.open(URL(string: "about:blank")!)
        let b = browser.open(URL(string: "about:blank")!)
        browser.select(b.id)
        for tab in [a, b] { tab.playsAVideoTheOwnerChose(in: browser) }
        return Setup(browser: browser, recorder: recorder, clock: clock, a: a, b: b, settings: settings, suite: suite)
    }

    /// From leaving the tab to WebKit saying its video floats.
    @Test func leavingATabIsTimedUntilItsVideoFloats() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.clock.now += 0.12
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.a.isFloating)
        #expect(setup.timed(.floating).map { ($0 * 1000).rounded() } == [120])
    }

    /// From coming back to the tab to WebKit saying its video is back in its page.
    @Test func comingBackIsTimedUntilTheVideoLands() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.webKitSays(setup.a, floating: true)
        setup.clock.now += 1
        setup.browser.select(setup.a.id)
        setup.clock.now += 0.6
        setup.webKitSays(setup.a, floating: false)
        #expect(!setup.a.isFloating)
        #expect(setup.timed(.landing).map { ($0 * 1000).rounded() } == [600])
    }

    /// Coming back to a tab whose video isn't floating times nothing, even
    /// when the video floats after all.
    @Test func comingBackBeforeTheVideoFloatsTimesNothing() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.clock.now += 0.05
        setup.browser.select(setup.a.id)
        setup.webKitSays(setup.a, floating: true)
        setup.webKitSays(setup.a, floating: false)
        #expect(setup.timed(.floating).isEmpty)
        #expect(setup.timed(.landing).isEmpty)
    }

    /// A video floated by the page's own button, or landed by the floating
    /// window's, is known, but no leave or return of the owner's is timed.
    @Test func floatingNobodyAskedForIsKnownNotTimed() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.webKitSays(setup.b, floating: true)
        #expect(setup.b.isFloating)
        setup.webKitSays(setup.b, floating: false)
        #expect(!setup.b.isFloating)
        #expect(setup.timed(.floating).isEmpty && setup.timed(.landing).isEmpty)
    }

    /// A leave with no video to float gets no word from WebKit: one that
    /// comes long after answers something else.
    @Test func aLateWordIsNotTheLeaves() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.clock.now += Recorder.presentingLongest + 1
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.a.isFloating)
        #expect(setup.timed(.floating).isEmpty)
    }

    /// Each leave is timed from itself: one unanswered doesn't start the next.
    @Test func aLeaveAgainIsTimedFromItself() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.clock.now += 2
        setup.browser.select(setup.a.id)
        setup.clock.now += 2
        setup.browser.select(setup.b.id)
        setup.clock.now += 0.08
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.timed(.floating).map { ($0 * 1000).rounded() } == [80])
    }

    /// The same video the owner chose floats from their own tab, never by
    /// itself from an Agent tab.
    @Test func anAgentTabsVideoNeverFloatsByItself() throws {
        let owners = try setup()
        defer { owners.close() }
        let agents = try setup(forAgents: true)
        defer { agents.close() }
        #expect(owners.browser.videoToFloat(in: owners.a) != nil)
        #expect(agents.browser.videoToFloat(in: agents.a) == nil)
        #expect(!agents.browser.float(agents.a))
    }

    /// An Agent tab's video is known to float, and never timed.
    @Test func anAgentTabIsNeverTimed() throws {
        let setup = try setup(forAgents: true)
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.clock.now += 0.1
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.a.isFloating)
        setup.browser.select(setup.a.id)
        setup.clock.now += 0.1
        setup.webKitSays(setup.a, floating: false)
        #expect(!setup.a.isFloating)
        #expect(setup.recorder.timings().allSatisfy { $0.kind != .floating && $0.kind != .landing })
    }

    /// NERDA_RECORDER=0 times nothing, and the video is still known to float.
    @Test func theRecordsSwitchLeavesFloatingKnown() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.recorder.switchedOn = false
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.a.isFloating)
        #expect(setup.timed(.floating).isEmpty)
    }

    /// With Auto Picture-in-Picture off, nothing is asked to float and
    /// nothing is timed.
    @Test func withTheSettingOffNothingIsTimed() throws {
        let setup = try setup(on: false)
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.webKitSays(setup.a, floating: true)
        #expect(setup.timed(.floating).isEmpty)
    }

    /// Floating and landing go in the feedback report by name.
    @Test func theReportCarriesFloatingAndLanding() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.browser.select(setup.a.id)
        setup.browser.select(setup.b.id)
        setup.clock.now += 0.25
        setup.webKitSays(setup.a, floating: true)
        setup.browser.select(setup.a.id)
        setup.clock.now += 0.5
        setup.webKitSays(setup.a, floating: false)
        #expect(setup.recorder.report.contains("floating: 250"))
        #expect(setup.recorder.report.contains("landing: 500"))
    }

    /// A page whose process ends takes its floating video with it, whether
    /// or not WebKit says so.
    @Test func aPageEndingIsNoLongerFloating() throws {
        let setup = try setup()
        defer { setup.close() }
        setup.webKitSays(setup.a, floating: true)
        setup.browser.pageEnded(setup.a.webView, reason: .crash)
        #expect(!setup.a.isFloating)
    }
}
