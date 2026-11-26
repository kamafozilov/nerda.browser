import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

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
        // Round after round outlasts the movie.
        try await watched.run("media.loop = true", mark: "loop")
        // Auto Picture-in-Picture on for this browser alone, in settings of the test's own.
        let suite = "dev.nerda.tests.floating.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        settings.set(true, forKey: PictureInPicture.key)
        bed.browser.pictureInPictureSettings = settings
        for round in 1...Self.rounds {
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
        let floating = recorder.timings().filter { $0.kind == .floating }.map(\.seconds)
        let landing = recorder.timings().filter { $0.kind == .landing }.map(\.seconds)
        print("Floating, \(floating.count) times: \(Self.summary(floating))")
        print("Landing, \(landing.count) times: \(Self.summary(landing))")
        // Leaving and coming back, in turn: a leave is timed to the new page shown.
        let switches = recorder.timings().filter { $0.kind == .tabSwitch }.map(\.seconds)
        let leaves = stride(from: 0, to: switches.count, by: 2).map { switches[$0] }
        print("Tab switch leaving the video, \(leaves.count) times: \(Self.summary(leaves))")
        #expect(floating.count == Self.rounds)
        #expect(landing.count == Self.rounds)
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
        #expect(page.lastArrival == .lastFrame)
        try await waitFor("Never landed") { !watched.tab.isFloating }
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
