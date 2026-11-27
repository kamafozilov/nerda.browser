import AppKit
import Foundation
import Observation
import Testing
import WebKit
@testable import Nerda
import MediaCheck

/// Where the floating video ends up follows where the owner is, however
/// quickly they move: really floating in the media test bed's hosted window,
/// Auto Picture-in-Picture on, each test holding `FloatingLock`. WebKit
/// ignores an ask while a change is under way; what the owner wants is
/// asked for again once WebKit says the change is done.
@Suite(.serialized)
@MainActor
struct FloatingFollowsTests {
    /// WebKit's words for a tab, in order, as `Tab.isFloating` takes them.
    @MainActor final class Words {
        private(set) var seen: [Bool] = []
        private let tab: Nerda.Tab

        init(_ tab: Nerda.Tab) {
            self.tab = tab
            follow()
        }

        private func follow() {
            withObservationTracking { _ = tab.isFloating } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.seen.append(self.tab.isFloating)
                    self.follow()
                }
            }
        }
    }

    /// A bed with two tabs, `other` and `watched`, `watched` on screen,
    /// playing (looped), heard by Nerda, and Auto Picture-in-Picture on in
    /// settings of the bed's own.
    @MainActor final class Setup {
        let bed: MediaTestBed
        let other: MediaPage
        let watched: MediaPage
        let words: Words
        private let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        private let settings: UserDefaults

        /// `browser`: the bed's, an incognito window's unless given.
        init(browser: Browser = browserRunningOutOfSight()) async throws {
            let bed = try await MediaTestBed(browser: browser)
            self.bed = bed
            other = try await bed.open(.file())
            let watched = try await bed.play(.file())
            self.watched = watched
            try await watched.run("media.loop = true", mark: "loop")
            try await waitFor("The page never played sound as far as Nerda knows") { watched.tab.playsAudio }
            words = Words(watched.tab)
            // On only now: opening a tab selects it, which leaves the one before.
            settings = try #require(UserDefaults(suiteName: suite))
            settings.set(true, forKey: PictureInPicture.key)
            bed.browser.pictureInPictureSettings = settings
        }

        func leave() { bed.browser.select(other.tab.id) }
        func comeBack() { bed.browser.select(watched.tab.id) }

        /// WebKit's own reading, beside its word: whether the video floats.
        var webKitFloats: Bool { watched.tab.page.map(bed.browser.floatingToggle.isActive) ?? false }

        /// Waits until it all settles with the video floating, or in its
        /// page and playing on there: WebKit's word and its own reading
        /// agree, and Nerda has nothing more asked of WebKit.
        func settled(floating: Bool, _ comment: String) async throws {
            let tab = watched.tab
            try await waitFor("\(comment): never settled \(floating ? "floating" : "in its page"); words \(words.seen)") {
                tab.isFloating == floating && webKitFloats == floating && words.seen.last == floating && tab.floatingAsked == nil
            }
            if floating { return }
            let media = try await watched.state().media
            try await waitFor("\(comment): stopped playing in its page at \(media) s") {
                let state = try await watched.state()
                return !state.paused && (state.media > media + 0.1 || state.media < media)
            }
        }

        func close() {
            bed.close()
            settings.removePersistentDomain(forName: suite)
        }
    }

    /// Leaving the tab and coming straight back, in the same moment, before
    /// WebKit has said the video floats: it floats, then lands again.
    @Test func leavingAndComingStraightBackEndsWithTheVideoInItsPage() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        setup.leave()
        setup.comeBack()
        try await setup.settled(floating: false, "Left and back")
        #expect(setup.words.seen == [true, false])
    }

    /// Coming back to the floating video and leaving again in the same
    /// moment: it lands, then floats again.
    @Test func comingBackAndLeavingStraightAwayEndsWithTheVideoFloating() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        setup.leave()
        try await setup.settled(floating: true, "Left")
        setup.comeBack()
        setup.leave()
        try await setup.settled(floating: true, "Back and left")
        #expect(setup.words.seen == [true, false, true])
    }

    /// Leaving again while the video flies back into its page (some 0.6 s,
    /// WebKit no longer reading it as floating but not yet saying it has
    /// landed): it floats again once it has landed.
    @Test func leavingWhileTheVideoFliesBackEndsWithTheVideoFloating() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        setup.leave()
        try await setup.settled(floating: true, "Left")
        setup.comeBack()
        try await waitFor("Never started landing") { setup.watched.tab.isFloating && !setup.webKitFloats }
        setup.leave()
        try await setup.settled(floating: true, "Left during the landing")
        #expect(setup.words.seen == [true, false, true])
    }

    /// Ten quick switches back and forth, all in one moment, end on the
    /// video's tab with it in its page; eleven end away with it floating.
    @Test(arguments: [10, 11])
    func quickSwitchesEndWithTheVideoWhereTheOwnerIs(switches: Int) async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        for index in 0..<switches {
            if index.isMultiple(of: 2) { setup.leave() } else { setup.comeBack() }
        }
        try await setup.settled(floating: !switches.isMultiple(of: 2), "\(switches) switches")
    }

    /// Ten switches back and forth, each as soon as WebKit has moved on from
    /// the one before (its reading or its word changed): in the middle of
    /// floating, of landing, or just after either ends.
    @Test func switchesAsWebKitMovesEndWithTheVideoInItsPage() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        for index in 0..<10 {
            let words = setup.words.seen.count
            let reading = setup.webKitFloats
            if index.isMultiple(of: 2) { setup.leave() } else { setup.comeBack() }
            try await waitFor("Switch \(index + 1): WebKit never moved on; words \(setup.words.seen)") {
                setup.words.seen.count > words || setup.webKitFloats != reading
            }
        }
        try await setup.settled(floating: false, "Ten switches")
    }

    /// The system's floating windows on screen, of every app: the owner's
    /// own may be among them, so a test goes by how many there are.
    static func floatingWindows() -> Int {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { $0[kCGWindowOwnerName as String] as? String == "Picture in Picture" }.count
    }

    /// Closing the tab whose video floats, or its window, ends the floating
    /// video: WebKit no longer has it floating, and the system's floating
    /// window goes.
    @Test(arguments: [false, true])
    func closingTheTabOrItsWindowEndsTheFloatingVideo(window: Bool) async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let without = Self.floatingWindows()
        setup.leave()
        try await setup.settled(floating: true, "Left")
        try await waitFor("The system's floating window never showed") { Self.floatingWindows() > without }
        let page = try #require(setup.watched.tab.page)
        if window { setup.bed.browser.closeAll() } else { setup.bed.browser.close(setup.watched.tab.id) }
        let toggle = setup.bed.browser.floatingToggle
        try await waitFor("Still floating in WebKit after the close") { !toggle.isActive(page) }
        try await waitFor("The system's floating window stayed") { Self.floatingWindows() <= without }
    }

    /// A video in page full screen, its tab left: the page leaves full
    /// screen, then the video floats, as the page itself tells the two.
    @Test func aVideoInFullScreenLeavesItThenFloats() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let page = setup.watched
        // The window stays put: only the page goes full screen.
        let window = try #require(setup.bed.window as? BedWindow)
        try await page.run("""
            window.times = {};
            document.addEventListener('fullscreenchange', () => {
                window.times[document.fullscreenElement ? 'entered' : 'left'] = performance.now();
            });
            media.addEventListener('webkitpresentationmodechanged', () => {
                if (media.webkitPresentationMode === 'picture-in-picture') window.times.floated ??= performance.now();
            });
            """, mark: "listen")
        try await page.run("await media.requestFullscreen()", mark: "full screen")
        try await waitFor("The page never went full screen") { setup.bed.browser.fullscreenTab == page.tab.id }
        try await waitFor("Nerda never took the window full screen with the page") { window.fullScreenAsks > 0 }
        // Hears it isn't covered again, should full screen have changed that (#161).
        page.tab.webView.hearsWindowCovered(false)
        let media = try await page.state().media
        try await waitFor("Stopped playing in full screen") {
            let state = try await page.state()
            return !state.paused && state.media > media + 0.1 && page.tab.playsAudio
        }
        setup.leave()
        try await setup.settled(floating: true, "Left in full screen")
        let times: [String: Double] = try await page.read("window.times")
        let left = try #require(times["left"], "Never left full screen: \(times)")
        let floated = try #require(times["floated"], "Never floated, as the page has it: \(times)")
        #expect(left <= floated, "Floated \(left - floated) ms before leaving full screen")
        #expect(try await page.read("document.fullscreenElement === null") == true)
        #expect(setup.bed.browser.fullscreenTab == nil)
    }
}

/// What the owner wants beside what WebKit says, with no window and nothing
/// really floating: WebKit's word is given here as WebKit gives it, and
/// pages are blank, so Nerda's script finds no video to ask. Each tab's
/// page is told as having a video the owner chose.
@MainActor
struct FloatingFollowsOwnerTests {
    @MainActor private final class Clock {
        var now: TimeInterval = 1000
    }

    /// A browser with Auto Picture-in-Picture on in settings of its own,
    /// on a clock that stands still, and two tabs, `b` on screen.
    private func setup() throws -> (browser: Browser, a: Nerda.Tab, b: Nerda.Tab, close: () -> Void) {
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(true, forKey: PictureInPicture.key)
        let clock = Clock()
        let browser = Browser(dataStore: .nonPersistent())
        browser.recorder = Recorder(clock: { clock.now })
        browser.floatingClock = { clock.now }
        let a = browser.open(URL(string: "about:blank")!)
        let b = browser.open(URL(string: "about:blank")!)
        browser.pictureInPictureSettings = settings
        // A video the owner chose, as its frame would tell it: the blank page
        // itself has none, so Nerda's script finds none to ask.
        for tab in [a, b] { tab.playsAVideoTheOwnerChose(in: browser) }
        return (browser, a, b, { settings.removePersistentDomain(forName: suite) })
    }

    /// One turn of the main loop on, when what follows WebKit's word is asked.
    private func nextTurn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    /// Asked to float a page with no video playing, the script says it found
    /// none: nothing is under way, and the next ask isn't held up by it.
    @Test func anAskThatFoundNoVideoHoldsUpNothing() async throws {
        let (browser, a, b, close) = try setup()
        defer { close() }
        browser.select(a.id)
        browser.select(b.id)
        #expect(a.floatingAsked?.floats == true)
        try await waitFor("Still under way after the script found no video") { a.floatingAsked == nil }
        #expect(a.wantsFloating)
    }

    /// The video floating while the owner is on another tab, closed in the
    /// system's floating window (or taken back by the page): the owner's own
    /// doing, not floated again.
    @Test func aVideoTheOwnerLandsThemselvesIsNotFloatedAgain() async throws {
        let (browser, a, b, close) = try setup()
        defer { close() }
        browser.select(a.id)
        browser.select(b.id)
        try await waitFor("Still under way after the script found no video") { a.floatingAsked == nil }
        // As if it floated after all, by the page's own button.
        browser.webView(a.webView, hasVideoInPictureInPictureDidChange: true)
        await nextTurn()
        browser.webView(a.webView, hasVideoInPictureInPictureDidChange: false)
        await nextTurn()
        #expect(!a.isFloating)
        #expect(!a.wantsFloating)
        #expect(a.floatingAsked == nil, "Asked again to float what the owner landed")
    }

    /// The owner coming back while Nerda's ask to float is under way: the
    /// video is landed once WebKit says it floats.
    @Test func comingBackDuringFloatingLandsItOnceWebKitSaysItFloats() async throws {
        let (browser, a, b, close) = try setup()
        defer { close() }
        browser.select(a.id)
        browser.select(b.id)
        let asked = try #require(a.floatingAsked)
        browser.select(a.id)
        #expect(a.floatingAsked?.number == asked.number, "Asked again while the first was under way")
        let asks = browser.floatingAsks
        browser.webView(a.webView, hasVideoInPictureInPictureDidChange: true)
        await nextTurn()
        #expect(browser.floatingAsks == asks + 1, "Never asked to land")
        #expect(a.floatingAsked?.floats ?? false == false)
        #expect(!a.wantsFloating)
    }
}
