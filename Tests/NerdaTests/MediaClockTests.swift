import Testing
@testable import Nerda

/// The media clock read against the wall clock (`MediaClock`), over
/// timelines made up here: what counts as media time jumping, which way,
/// and by how much, to within the 20 ms between two samples.
struct MediaClockTests {
    /// Samples every 20 ms of wall time, the media running at `rate` from `media`.
    private func playing(from wall: Double, to end: Double, media: Double, rate: Double = 1) -> [MediaClock.Sample] {
        stride(from: wall, through: end, by: 0.02).map {
            MediaClock.Sample(wall: $0, media: media + ($0 - wall) * rate, paused: false, rate: rate)
        }
    }

    private func paused(from wall: Double, to end: Double, at media: Double) -> [MediaClock.Sample] {
        stride(from: wall, through: end, by: 0.02).map { MediaClock.Sample(wall: $0, media: media, paused: true, rate: 1) }
    }

    @Test func mediaRunningWithTheWallClockHasNoJump() {
        let clock = MediaClock(samples: playing(from: 10, to: 12, media: 3))
        #expect(clock.jumps(over: 0.05).isEmpty)
    }

    /// The wall time a pause lasted is not media time lost.
    @Test func aPauseAndPlayWhereItStoppedHasNoJump() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + paused(from: 11.01, to: 15, at: 4)
                               + playing(from: 15.01, to: 16, media: 4))
        #expect(clock.jumps(over: 0.05).isEmpty)
    }

    @Test func mediaMovedOnDuringAPauseIsAJumpForwardOfThatMuch() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + paused(from: 11.01, to: 12, at: 4)
                               + paused(from: 12.01, to: 13, at: 6) + playing(from: 13.01, to: 14, media: 6),
                               marks: [.init(wall: 11, name: "pause"), .init(wall: 12, name: "seek"), .init(wall: 13, name: "play")])
        let jumps = clock.jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(abs((jumps.first?.by ?? 0) - 2) <= 0.02)
        #expect(jumps.first?.after == "seek")
    }

    @Test func mediaGoingBackWhilePlayingIsAJumpBack() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + playing(from: 11.02, to: 12, media: 2.5))
        let jumps = clock.jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(abs((jumps.first?.by ?? 0) - -1.5) <= 0.02)
        #expect(jumps.first?.after == nil)
    }

    @Test func fasterPlayingIsNoJump() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + playing(from: 11.02, to: 12, media: 4.02, rate: 2))
        #expect(clock.jumps(over: 0.05).isEmpty)
    }

    /// Sampling's own unevenness is no fault: within the tolerance either way.
    @Test func moveWithinTheToleranceIsNoJump() {
        var samples = playing(from: 10, to: 11, media: 3)
        samples[20].media += 0.03
        samples[30].media -= 0.03
        #expect(MediaClock(samples: samples).jumps(over: 0.05).isEmpty)
        #expect(!MediaClock(samples: samples).jumps(over: 0.01).isEmpty)
    }

    /// As WebKit reports it after a play: held where it paused for a while,
    /// then on with the wall clock from where it truly started. Media fell
    /// behind the wall clock and caught up, never ahead of it: no jump.
    /// (Measured 2026-11-27: held 100–250 ms, then up to 90 ms in one 20 ms
    /// step, while the frames shown ran on without one missing.)
    @Test func mediaTimeReportedLateThenCaughtUpIsNoJump() {
        let held = stride(from: 11.21, through: 11.29, by: 0.02).map { MediaClock.Sample(wall: $0, media: 4, paused: false, rate: 1) }
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + paused(from: 11.01, to: 11.2, at: 4)
                               + held + playing(from: 11.31, to: 12, media: 4.11))
        #expect(clock.jumps(over: 0.01).isEmpty)
    }

    /// Ahead of the wall clock from any moment before, however late it was
    /// reported in between: a jump.
    @Test func mediaAheadOfTheWallClockAfterBeingLateIsAJump() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + paused(from: 11.01, to: 11.2, at: 4)
                               + playing(from: 11.21, to: 12, media: 4.52))
        let jumps = clock.jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(abs((jumps.first?.by ?? 0) - 0.5) <= 0.02)
    }
}
