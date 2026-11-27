import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda
import MediaCheck

/// A video really floating (the system's Picture in Picture) as the owner
/// leaves its tab, with Auto Picture-in-Picture on, and landing as they
/// come back, in the media test bed's hosted window: Nerda knows it from
/// WebKit's word, and times both in its record. The system's floating
/// window shows for a moment; every test here holds `FloatingLock` while
/// anything floats. Serialized, as every suite that really plays media is.
@Suite(.serialized)
@MainActor
struct FloatingTests {
    /// How many times the video floats and lands: `NERDA_FLOATING_ROUNDS`
    /// for a measurement (`NERDA_FLOATING_ROUNDS=40 swift test --filter
    /// FloatingTests`), else a few.
    private static let rounds = ProcessInfo.processInfo.environment["NERDA_FLOATING_ROUNDS"].flatMap(Int.init) ?? 2

    @Test func aVideoLeftFloatsAndLandsAsWebKitSays() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let recorder = Recorder()
        bed.browser.recorder = recorder
        let other = try await bed.open(.file())
        let watched = try await bed.play(.file())
        try await Self.floatAndLand(watched, leavingFor: other, in: bed, rounds: Self.rounds)
        let floating = recorder.timings().filter { $0.kind == .floating }.map(\.seconds)
        let landing = recorder.timings().filter { $0.kind == .landing }.map(\.seconds)
        print("Floating, \(floating.count) times: \(Self.summary(floating))")
        print("Landing, \(landing.count) times: \(Self.summary(landing))")
        // A leave's switch is timed to the new page shown, after WebKit's
        // word: the one recorded straight after each floating.
        let timings = recorder.timings()
        let leaves = zip(timings, timings.dropFirst()).filter { $0.kind == .floating && $1.kind == .tabSwitch }.map(\.1.seconds)
        print("Tab switch leaving the video, \(leaves.count) times: \(Self.summary(leaves))")
        #expect(floating.count == Self.rounds)
        #expect(landing.count == Self.rounds)
    }

    /// An embedded player: the video is in a frame of a page from another
    /// origin, and the page itself has none.
    @Test func aVideoInAFrameFromAnotherOriginFloatsAndLands() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let other = try await bed.open(.file())
        let watched = try await bed.play(.file(), inFrame: true)
        try await Self.floatAndLand(watched, leavingFor: other, in: bed, rounds: 2)
    }

    /// On a WebKit without the toggle's calls, the video in the page itself
    /// floats and lands by Nerda's script, as before them.
    @Test func withWebKitsTogglesCallsMissingAVideoInThePageStillFloats() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let bed = try await MediaTestBed()
        defer { bed.close() }
        var asked = 0
        bed.browser.floatingToggle = .webKit(answers: { _, _ in asked += 1; return false })
        let other = try await bed.open(.file())
        let watched = try await bed.play(.file())
        try await Self.floatAndLand(watched, leavingFor: other, in: bed, rounds: 2)
        #expect(asked > 0, "Floating never asked whether the page answers to the toggle's calls")
    }

    /// What floating needs is made ready as a page starts playing sound, and
    /// never for a page playing a video without: leaving it floats nothing.
    @Test func onlyAPagePlayingSoundIsMadeReadyToFloat() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let bed = try await MediaTestBed()
        defer { bed.close() }
        var readied: [ObjectIdentifier] = []
        var toggle = FloatingToggle.webKit()
        let makeReady = toggle.makeReady
        toggle.makeReady = { page in
            readied.append(ObjectIdentifier(page))
            makeReady(page)
        }
        bed.browser.floatingToggle = toggle
        let heard = try await bed.play(.file())
        try await waitFor("A page playing sound was never made ready") { readied.contains(ObjectIdentifier(heard.tab.webView)) }
        let silent = try await bed.open(.file())
        try await silent.run("media.muted = true", mark: "mute")
        try await silent.play()
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        settings.set(true, forKey: PictureInPicture.key)
        bed.browser.pictureInPictureSettings = settings
        // Played on for a while, then left.
        _ = try await silent.clock(around: {}, before: 0.5, after: 0)
        bed.browser.select(heard.tab.id)
        _ = try await heard.clock(around: {}, before: 0.5, after: 0)
        #expect(!silent.tab.playsAudio)
        #expect(!readied.contains(ObjectIdentifier(silent.tab.webView)))
        #expect(!silent.tab.isFloating)
    }

    /// Leaving the tab, the tab list shows the new tab at once, while the
    /// page left stays in sight until WebKit says its video floats; only
    /// then is the new page shown, and the page left's last frame taken,
    /// which is what comes back with the tab.
    @Test func thePageLeftStaysInSightUntilItsVideoFloats() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let bed = try await MediaTestBed()
        defer { bed.close() }
        bed.browser.recorder = Recorder()
        let other = try await bed.open(.file())
        let watched = try await bed.play(.file())
        try await waitFor("The video never played with sound") { watched.tab.playsAudio }
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        settings.set(true, forKey: PictureInPicture.key)
        bed.browser.pictureInPictureSettings = settings
        let page = watched.tab.webView, next = other.tab.webView
        // WebKit's word, not the wait, ends the keep here (the wait has a
        // test of its own): a busy Mac can be slower to float than 300 ms.
        bed.browser.floatingWaitHere = 3600
        // How the window stood the moment WebKit said the video floats.
        var atTheWord: (inSight: Bool, shown: Bool, nextShown: Bool, frameKept: Bool)?
        withObservationTracking { _ = watched.tab.isFloating } onChange: {
            MainActor.assumeIsolated {
                atTheWord = (bed.browser.inSight === watched.tab, !page.isHidden, !next.isHidden, page.keepsLastFrame)
            }
        }
        bed.browser.select(other.tab.id)
        #expect(bed.browser.selected === other.tab)
        #expect(bed.browser.inSight === watched.tab)
        try await waitFor("Never floated") { watched.tab.isFloating }
        let word = try #require(atTheWord)
        #expect(word.inSight, "The page left was no longer kept in sight when its video floated")
        #expect(word.shown && !word.nextShown, "The page left was hidden before its video floated")
        #expect(!word.frameKept, "The page left's last frame was taken before its video floated")
        try await waitFor("The new page never showed") { !next.isHidden && page.isHidden }
        try await waitFor("The page left's last frame was never taken") { page.keepsLastFrame }
        bed.browser.select(watched.tab.id)
        try await waitFor("The tab never came back") { page.lastArrival != nil }
        #expect(page.lastArrival == .lastFrame, "Came back as \(String(describing: page.lastArrival))")
        try await waitFor("Never landed") { !watched.tab.isFloating }
    }

    /// Turns Auto Picture-in-Picture on for `bed`'s browser alone, then
    /// leaves `watched` for `other` and comes back, `rounds` times: each
    /// time its video floats, lands, and plays on in its page.
    static func floatAndLand(_ watched: MediaPage, leavingFor other: MediaPage, in bed: MediaTestBed, rounds: Int) async throws {
        // Round after round outlasts the movie.
        try await watched.run("media.loop = true", mark: "loop")
        // Heard by Nerda before it is left, as the owner's video has been
        // by then: WebKit says so a moment after it plays.
        try await waitFor("The page never played sound as far as Nerda knows") { watched.tab.playsAudio }
        // On only now: opening a tab selects it, which leaves the one before.
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        settings.set(true, forKey: PictureInPicture.key)
        bed.browser.pictureInPictureSettings = settings
        for round in 1...rounds {
            bed.browser.select(other.tab.id)
            try await waitFor("Round \(round): never floated") { watched.tab.isFloating }
            bed.browser.select(watched.tab.id)
            try await waitFor("Round \(round): never landed") { !watched.tab.isFloating }
            // On only once it plays on in its page.
            let media = try await watched.state().media
            var state: MediaPage.State?
            try await waitFor("Round \(round): stopped playing in its page at \(media) s: \(String(describing: state))") {
                state = try await watched.state()
                return state.map { !$0.paused && ($0.media > media + 0.1 || $0.media < media) } ?? false
            }
        }
    }

    /// The first, then the median, 95th percentile and worst of the rest, in ms.
    static func summary(_ seconds: [TimeInterval]) -> String {
        guard let first = seconds.first else { return "none" }
        let ms = { (value: TimeInterval) in Int((value * 1000).rounded()) }
        let rest = seconds.dropFirst().sorted()
        guard !rest.isEmpty else { return "first \(ms(first))" }
        let at = { (share: Double) in rest[min(rest.count - 1, Int((Double(rest.count) * share).rounded(.up)) - 1)] }
        return "first \(ms(first)), then median \(ms(at(0.5))), 95th percentile \(ms(at(0.95))), worst \(ms(rest.last!)); all: \(seconds.map(ms))"
    }
}
