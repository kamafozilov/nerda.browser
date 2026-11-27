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
            try await waitFor(comment) { page.tab.isFloating }
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
        try await page.waitForNoOwnersInput()
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
        try await page.waitForNoOwnersInput()
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

    /// A video the page started with its sound on, as a hover preview, stays.
    @Test func aVideoThePageStartedWithSoundStaysInItsPage() async throws {
        let setup = try await Setup()
        defer { setup.close() }
        let page = try await setup.bed.open(.file(), startingByItself: true)
        try await heard(page, "playing with sound by itself") { $0.playing && !$0.muted && !$0.ownerStarted }
        setup.bed.clock.now += 60
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
