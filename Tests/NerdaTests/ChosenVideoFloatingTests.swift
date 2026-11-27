import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

/// Only a video the owner chose floats as they leave its tab, in the media
/// test bed's hosted window, on media generated as the test runs: what the
/// page tells Nerda of its videos, and Nerda's choice at the leave. How long
/// a video has been heard is on the bed's clock, moved on by the test. The
/// bed's browser is an incognito one (a store of its own, kept in memory),
/// so these hold for incognito windows. Each test holds `FloatingLock`: a
/// test that floats nothing would float should the rule break.
@Suite(.serialized)
@MainActor
struct ChosenVideoFloatingTests {
    /// A bed with Auto Picture-in-Picture on in settings of the test's own,
    /// and a first tab with nothing playing, to leave others for.
    @MainActor private final class Setup {
        let lock: FloatingLock
        let bed: MediaTestBed
        let other: MediaPage
        let settings: UserDefaults
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"

        init() async throws {
            lock = try await FloatingLock.take()
            bed = try await MediaTestBed()
            other = try await bed.open(.file())
            settings = UserDefaults(suiteName: suite)!
            bed.browser.pictureInPictureSettings = settings
        }

        /// Turned on once the tabs are open: opening one leaves another.
        func turnOn(_ on: Bool = true) { settings.set(on, forKey: PictureInPicture.key) }

        /// Leaves `page`'s tab for the first, and waits for its video to float.
        func leaveAndFloat(_ page: MediaPage, _ comment: Comment = "The video never floated") async throws {
            bed.browser.select(other.tab.id)
            let tab = page.tab
            try await waitFor("""
                \(comment.rawValue): sound \(tab.playsAudio), asked \(String(describing: tab.floatingAsked)), \
                videos \(tab.videos.all.map(\.told))
                """) { tab.isFloating }
        }

        /// Leaves `page`'s tab for the first: Nerda asks nothing to float.
        func leaveAndStay(_ page: MediaPage, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(bed.browser.videoToFloat(in: page.tab) == nil, sourceLocation: sourceLocation)
            bed.browser.select(other.tab.id)
            #expect(page.tab.timing.presenting == nil, "Nerda asked the video to float", sourceLocation: sourceLocation)
        }

        /// Back on `page`'s tab, its video landed.
        func comeBack(to page: MediaPage) async throws {
            bed.browser.select(page.tab.id)
            try await waitFor("The video never landed") { !page.tab.isFloating }
        }

        func close() {
            bed.close()
            settings.removePersistentDomain(forName: suite)
            lock.release()
        }
    }

    /// Waits for Nerda to have heard of `page`'s video as `told` says.
    private func heard(_ page: MediaPage, _ what: String, _ told: (PageVideos.Told) -> Bool) async throws {
        try await waitFor("Nerda never heard the video \(what): \(page.tab.videos.all)") {
            page.tab.videos.all.contains { told($0.told) }
        }
    }

    /// A click of the owner's mouse in the middle of the page, as the
    /// window gives it to the page.
    private func ownerClick(_ page: WKWebView) {
        let point = page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: page.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { page.mouseDown(with: event) } else { page.mouseUp(with: event) }
        }
    }

    /// Started by the owner's own click, heard for three seconds: it floats
    /// as they leave, and lands as they come back. The bed's window is an
    /// incognito one's.
    @Test func aVideoTheOwnerClickedToPlayFloats() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        #expect(setup.bed.browser.isPrivate)
        let page = try await setup.bed.open(.file())
        try await page.run("media.addEventListener('click', () => media.play())", mark: "click to play")
        ownerClick(page.tab.webView)
        try await heard(page, "started by the owner") { $0.playing && $0.ownerStarted && !$0.muted }
        setup.bed.clock.now += FloatingRule.heardAtLeast
        setup.turnOn()
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// Under three seconds heard it stays; past them it floats.
    @Test func aVideoHeardUnderThreeSecondsStaysInItsPage() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.open(.file())
        try await page.play()
        try await heard(page, "playing") { $0.playing && $0.ownerStarted }
        setup.bed.clock.now += FloatingRule.heardAtLeast - 0.1
        setup.turnOn()
        setup.leaveAndStay(page)
        setup.bed.browser.select(page.tab.id)
        setup.bed.clock.now += 0.1
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// A feed's video plays muted by itself and stays; once the owner turns
    /// its sound on, it floats.
    @Test func aFeedVideoFloatsOnlyOnceTheOwnerUnmutesIt() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.open(.file(), startingByItself: true, muted: true)
        try await heard(page, "playing muted by itself") { $0.playing && $0.muted && !$0.ownerStarted }
        setup.bed.clock.now += 60
        setup.turnOn()
        setup.leaveAndStay(page)
        setup.bed.browser.select(page.tab.id)
        try await page.run("media.muted = false", mark: "unmute")
        try await heard(page, "unmuted by the owner") { $0.playing && !$0.muted && $0.ownerStarted }
        setup.bed.clock.now += FloatingRule.heardAtLeast
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// A page the owner went to by a link, starting its video with sound by
    /// itself as it comes in, as a watch page opened from a link does: a
    /// video they chose, though they pressed nothing in it.
    @Test func aPageReachedByALinkStartingItsVideoWithSoundFloats() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let first = try await setup.bed.open(.file())
        let source: String = try await first.read("media.src")
        let linked = try await setup.bed.server.serve(
            "/linked", html: MediaPage.html(source: .src(try #require(URL(string: source))), startingByItself: true))
        // The owner's click on a link: one of Nerda's scripts, which WebKit
        // takes for a click of theirs.
        try await first.run("""
            const link = document.createElement('a');
            link.href = \(String(reflecting: linked.absoluteString));
            document.body.append(link);
            link.click();
            """, mark: "link")
        try await waitFor("The link never led to its page") { first.tab.webView.url == linked && !first.tab.webView.isLoading }
        let page = MediaPage(tab: first.tab)
        try await heard(page, "playing with sound by itself") { $0.playing && !$0.muted && !$0.ownerStarted }
        setup.bed.clock.now += FloatingRule.heardAtLeast
        setup.turnOn()
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// The same page starting its video with sound long after it came in,
    /// with nothing of the owner's behind it, as an ad does: it stays. No
    /// script of Nerda's runs in the page, which would read as the owner's
    /// input in effect: it loads, Nerda hears of its video, and it starts
    /// as its window is resized.
    @Test func aVideoStartingWithSoundLongAfterThePageCameInStays() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let bed = setup.bed
        let movie = try await GeneratedMovie.cachedMP4(seconds: 30, sound: .tone(hertz: 440))
        let source = try await bed.server.serve("/later.mp4", movie, type: "video/mp4")
        let url = try await bed.server.serve("/later", html: MediaPage.html(source: .src(source), startingOnResize: true))
        let tab = bed.browser.open(URL(string: "about:blank")!)
        tab.webView.hearsWindowCovered(false)
        try await waitFor("The tab never joined the bed's window") { tab.webView.window === bed.window }
        tab.go(to: url)
        let page = MediaPage(tab: tab)
        try await heard(page, "loaded") { $0.hasPicture && !$0.playing }
        bed.clock.now += FloatingRule.firstMoments + 1
        var wide = false
        try await waitFor("The page never started its video: \(tab.videos.all)") {
            wide.toggle()
            bed.window.setContentSize(NSSize(width: wide ? 600 : 640, height: wide ? 380 : 400))
            return tab.videos.all.contains { $0.told.playing }
        }
        try await heard(page, "playing with sound by itself") { $0.playing && !$0.muted && !$0.ownerStarted }
        bed.clock.now += 60
        setup.turnOn()
        setup.leaveAndStay(page)
    }

    /// A muted tab's video stays; with the tab's sound on again, it floats.
    @Test func aMutedTabsVideoStaysInItsPage() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.play(.file())
        setup.turnOn()
        page.tab.isMuted = true
        setup.leaveAndStay(page)
        setup.bed.browser.select(page.tab.id)
        page.tab.isMuted = false
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// Sound alone, the owner's own, with no video playing: nothing floats.
    @Test func aPageWithSoundOnlyFloatsNothing() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.play(.file())
        try await page.pause()
        try await page.run("""
            const sound = new Audio(media.src);
            sound.volume = \(MediaTestBed.inaudible);
            document.body.append(sound);
            await sound.play();
            """, mark: "sound")
        try await heard(page, "paused") { !$0.playing }
        setup.bed.clock.now += 60
        setup.turnOn()
        setup.leaveAndStay(page)
    }

    @Test func withAutoPictureInPictureOffNothingFloats() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.play(.file())
        setup.turnOn(false)
        setup.leaveAndStay(page)
    }

    /// Of two videos the owner plays in one page, the larger floats, though
    /// the smaller came first to the page and to Nerda.
    @Test func ofTwoVideosTheLargestFloats() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.play(.file())
        try await page.run("""
            media.style = 'width: 160px; height: 90px';
            const large = window.large = document.createElement('video');
            large.style = 'width: 480px; height: 270px';
            large.volume = \(MediaTestBed.inaudible);
            large.src = media.src;
            document.body.append(large);
            await large.play();
            """, mark: "large")
        try await waitFor("Nerda never heard of both playing: \(page.tab.videos.all)") {
            page.tab.videos.all.filter { $0.told.playing && $0.told.ownerStarted }.count == 2
        }
        setup.bed.clock.now += FloatingRule.heardAtLeast
        setup.turnOn()
        try await setup.leaveAndFloat(page)
        struct Modes: Decodable { var large: String; var small: String }
        let json = try await page.tab.webView.callAsyncJavaScript("""
            return JSON.stringify({ large: large.webkitPresentationMode, small: media.webkitPresentationMode });
            """, contentWorld: .page) as? String
        let modes = try JSONDecoder().decode(Modes.self, from: Data(try #require(json).utf8))
        #expect(modes.large == "picture-in-picture")
        #expect(modes.small == "inline")
        try await setup.comeBack(to: page)
    }

    /// The owner's video floats, not a larger one beside it that is paused,
    /// or playing muted: WebKit's toggle picked the larger one (measured).
    @Test func aVideoBesideALargerSilentOneFloats() async throws {
        for larger in ["paused", "muted"] {
            let setup = try await Setup()
            defer { setup.close() }
            let page = try await setup.bed.play(.file())
            try await page.run("""
                media.style = 'width: 160px; height: 90px';
                const large = window.large = document.createElement('video');
                large.style = 'width: 480px; height: 270px';
                large.volume = \(MediaTestBed.inaudible);
                large.src = media.src;
                document.body.append(large);
                \(larger == "muted" ? "large.muted = true; await large.play();" : "await new Promise(r => large.addEventListener('loadeddata', r, { once: true }));")
                """, mark: "large")
            try await waitFor("Nerda never heard of both: \(page.tab.videos.all)") { page.tab.videos.all.count == 2 }
            setup.bed.clock.now += FloatingRule.heardAtLeast
            setup.turnOn()
            try await setup.leaveAndFloat(page, "The video never floated beside a larger \(larger) one")
            let modes = try await page.read("[media.webkitPresentationMode, large.webkitPresentationMode]") as [String]
            #expect(modes == ["picture-in-picture", "inline"], "Beside a larger \(larger) one")
            try await setup.comeBack(to: page)
        }
    }

    /// The owner's video going on to another, as a player's next video does,
    /// and its sound coming a moment after it plays: Nerda hears it again.
    @Test func aNextVideoInTheSameElementIsHeard() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.play(.file())
        // Returns once the next one plays: what the page told of the first
        // has come in by then, so Nerda's word on the next is what is waited for.
        try await page.run("""
            const next = media.src;
            media.src = '';
            media.load();
            media.addEventListener('loadedmetadata', () => media.play(), { once: true });
            const playing = bed.event('playing');
            media.src = next;
            await playing;
            """, mark: "next")
        try await heard(page, "playing on with its sound") { $0.playing && !$0.muted && $0.hasSound && $0.ownerStarted }
        setup.bed.clock.now += FloatingRule.heardAtLeast
        setup.turnOn()
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// The same across two windows, each its own browser: the second
    /// window's video floating lands the first's.
    @Test func oneVideoFloatsAtATimeAcrossWindows() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let first = try await setup.bed.play(.file())
        setup.turnOn()
        let bed = try await MediaTestBed()
        defer { bed.close() }
        bed.browser.pictureInPictureSettings = setup.settings
        let elsewhere = try await bed.open(.file())
        let second = try await bed.play(.file())
        try await setup.leaveAndFloat(first, "The first window's video never floated")
        bed.browser.select(elsewhere.tab.id)
        try await waitFor("The second window's video never floated") { second.tab.isFloating }
        try await waitFor("The first window's video never landed") { !first.tab.isFloating }
        bed.browser.select(second.tab.id)
        try await waitFor("The second window's video never landed") { !second.tab.isFloating }
    }

    /// A video in a frame from another origin floats by Nerda's own script
    /// too, in its frame, where WebKit's toggle is missing.
    @Test func withoutWebKitsToggleAVideoInAFrameStillFloats() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        setup.bed.browser.floatingToggle = .webKit(answers: { _, _ in false })
        let page = try await setup.bed.play(.file(), inFrame: true)
        setup.turnOn()
        try await setup.leaveAndFloat(page)
        try await setup.comeBack(to: page)
    }

    /// With one tab's video floating, leaving another tab with its own
    /// lands the one floating and floats the other.
    @Test func oneVideoFloatsAtATime() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let first = try await setup.bed.play(.file())
        let second = try await setup.bed.play(.file())
        setup.turnOn()
        try await setup.leaveAndFloat(second, "The second never floated")
        setup.bed.browser.select(first.tab.id)
        try await setup.leaveAndFloat(first, "The first never floated")
        try await waitFor("The second never landed") { !second.tab.isFloating }
        #expect(first.tab.isFloating)
        try await setup.comeBack(to: first)
    }
}
