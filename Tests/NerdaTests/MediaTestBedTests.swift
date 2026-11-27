import Testing
import WebKit
@testable import Nerda

/// The media test bed (`MediaTestBed`): media made as the test runs, served
/// on this Mac and played in a hosted window, its clock read around an
/// action. Serialized, as every suite that really plays media is.
@Suite(.serialized)
@MainActor
struct MediaTestBedTests {
    @Test func aGeneratedVideoPlaysInAHostedWindowWithoutBeingHeard() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.file())
        let state = try await page.state()
        #expect(page.tab.webView.window === bed.window)
        #expect(state.videoWidth == 320 && state.videoHeight == 180)
        #expect(state.hasSound)
        #expect(!state.muted && state.volume <= 0.001)
        let clock = try await page.clock(around: {})
        let first = try #require(clock.samples.first), last = try #require(clock.samples.last)
        #expect(last.media - first.media > 0.5)
        #expect(bed.server.requests.contains { $0.hasPrefix("GET /media/1.mp4") })
    }

    @Test func pausingAndPlayingAVideoFileLeavesMediaTimeContinuous() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.file())
        let clock = try await page.clock(around: {
            try await page.pause()
            try await page.play()
        })
        #expect(clock.marks.map(\.name) == ["pause", "play"])
        #expect(clock.jumps(over: MediaClock.tolerance).isEmpty, "\(clock.record)")
    }

    /// The same check, with the page seeking two seconds on while paused.
    @Test func aSeekDuringThePauseIsAJumpOfItsLength() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.file())
        let clock = try await page.clock(around: {
            try await page.pause()
            try await page.seek(to: try await page.state().media + 2)
            try await page.play()
        })
        let jumps = clock.jumps(over: MediaClock.tolerance)
        #expect(jumps.count == 1)
        #expect(abs((jumps.first?.by ?? 0) - 2) < MediaClock.tolerance)
        #expect(jumps.first?.after == "seek")
    }
}
