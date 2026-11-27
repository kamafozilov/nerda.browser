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

    /// Reported late as it first started, then paused and moved on two
    /// seconds: the jump is two seconds, measured from where it paused, not
    /// less by how late it started.
    @Test func aJumpIsMeasuredFromTheLastTimeKnownNotFromALateStart() {
        let held = stride(from: 10, through: 10.2, by: 0.02).map { MediaClock.Sample(wall: $0, media: 0, paused: false, rate: 1) }
        let clock = MediaClock(samples: held + playing(from: 10.22, to: 11, media: 0.02) + paused(from: 11.01, to: 11.5, at: 0.8)
                               + paused(from: 11.51, to: 12, at: 2.8) + playing(from: 12.01, to: 12.5, media: 2.8))
        let jumps = clock.jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(abs((jumps.first?.by ?? 0) - 2) <= 0.02)
    }

    /// A pause at media 0.4 s and a play, as WebKit reported it in full
    /// runs: held where it played from, then run on as its own estimate
    /// to `estimate`, then back, at wall time `takeBack`, to the very time
    /// it was held at, then on with the media from where it truly started
    /// (`start`, wall time) and, with `skip`, that much further on.
    private func takenBack(estimate: Double, takeBack: Double, start: Double, skip: Double = 0) -> MediaClock {
        let held = 0.4, estimateFrom = takeBack - 0.02 - (estimate - held)
        var samples = stride(from: 10, through: 10.2, by: 0.02).map {
            MediaClock.Sample(wall: $0, media: 0.2 + ($0 - 10), paused: false, rate: 1)
        }
        samples += paused(from: 10.21, to: 10.25, at: held)
        samples += stride(from: 10.26, through: 10.32, by: 0.02).map { MediaClock.Sample(wall: $0, media: held, paused: false, rate: 1) }
        samples += stride(from: 10.34, through: takeBack - 0.01, by: 0.02).map {
            MediaClock.Sample(wall: $0, media: held + ($0 - estimateFrom), paused: false, rate: 1)
        }
        samples.append(MediaClock.Sample(wall: takeBack, media: held, paused: false, rate: 1))
        samples += stride(from: takeBack + 0.02, through: 11, by: 0.02).map {
            MediaClock.Sample(wall: $0, media: held + ($0 - start) + skip, paused: false, rate: 1)
        }
        return MediaClock(samples: samples, marks: [.init(wall: 10.205, name: "pause"), .init(wall: 10.255, name: "play")])
    }

    /// WebKit taking back its estimate after a play, as it did in a full
    /// run: on to 0.462 s and back to 0.400 s, the time it was held at, then
    /// on from where it truly started. Seen from the sample before, 62 ms
    /// back and then 87 ms on; but the media never went back, and never
    /// got further than the wall clock let it since the pause.
    @Test func webKitTakingBackItsEstimateAfterAPlayIsNoJump() {
        let clock = takenBack(estimate: 0.462, takeBack: 10.4, start: 10.313)
        #expect(clock.jumps(over: 0.05).isEmpty)
    }

    /// The same, the estimate taken back by less than the tolerance: the
    /// time it went back to was late, and media measured from it ahead.
    @Test func anEstimateTakenBackWithinTheToleranceLeavesNoJumpEither() {
        let clock = takenBack(estimate: 0.44, takeBack: 10.38, start: 10.314)
        #expect(clock.jumps(over: 0.05).isEmpty)
    }

    /// Media further on than the wall clock let it since the pause is a
    /// jump, an estimate taken back or not.
    @Test func mediaAheadOfThePauseAfterATakeBackIsAJump() {
        let jumps = takenBack(estimate: 0.462, takeBack: 10.4, start: 10.313, skip: 0.2).jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(jumps.first.map { $0.by > 0.1 && $0.by < 0.2 } == true)
    }

    /// Back to any other time than the one it was held at is a jump back.
    @Test func goingBackToAnotherTimeAfterAPlayIsAJump() {
        var samples = takenBack(estimate: 0.462, takeBack: 10.4, start: 10.313).samples
        let back = samples.firstIndex { $0.wall == 10.4 }!
        samples[back].media -= 0.001
        let jumps = MediaClock(samples: samples).jumps(over: 0.05)
        #expect(jumps.first.map { abs($0.by - -0.063) < 0.001 } == true)
    }

    /// Back to the time it was held at, but after playing on for longer
    /// than WebKit ever ran on by its own estimate: a jump back.
    @Test func goingBackToWhereItWasHeldLongAgoIsAJump() {
        let held = stride(from: 10, through: 10.1, by: 0.02).map { MediaClock.Sample(wall: $0, media: 3, paused: false, rate: 1) }
        let clock = MediaClock(samples: held + playing(from: 10.12, to: 11, media: 3.02)
                               + [MediaClock.Sample(wall: 11.02, media: 3, paused: false, rate: 1)] + playing(from: 11.04, to: 11.5, media: 3.02))
        let jumps = clock.jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(jumps.first.map { abs($0.by - -0.9) < 0.03 } == true)
    }

    /// A start reported late in two steps, as with the page's own sampling
    /// held up (recorded with the page busy 30 ms in every 50, the first
    /// step made smaller): part of the way, still late, then the rest.
    /// Measured from the first step, 66 ms ahead; from the pause, behind.
    @Test func aStartReportedLateInTwoStepsIsNoJump() {
        let clock = MediaClock(samples: playing(from: 10, to: 10.26, media: 0.04) + paused(from: 10.27, to: 10.27, at: 0.3014)
                               + [0.3023, 0.3023, 0.3023, 0.308].enumerated().map {
                                   MediaClock.Sample(wall: 10.38 + [0, 0.03, 0.082, 0.134][$0.offset], media: $0.element, paused: false, rate: 1)
                               }
                               + playing(from: 10.566, to: 11.2, media: 0.426))
        #expect(clock.jumps(over: 0.05).isEmpty)
    }

    /// Media slower than the wall clock, then further on than the wall
    /// clock let it since it last kept up: a jump of that much further.
    @Test func mediaAheadAfterPlayingSlowIsAJumpOfWhatItGainedOnTheWallClock() {
        let slow = stride(from: 11.02, through: 11.5, by: 0.02).map { MediaClock.Sample(wall: $0, media: 4 + ($0 - 11) / 2, paused: false, rate: 1) }
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + slow + playing(from: 11.52, to: 12, media: 4.72))
        let jumps = clock.jumps(over: 0.05)
        #expect(jumps.count == 1)
        #expect(jumps.first.map { abs($0.by - 0.2) < 0.02 } == true)
    }

    /// A held sample taken twice in the same millisecond, as the page does
    /// with a media event and its own tick, is still held: not known.
    @Test func aHeldSampleTakenTwiceAtOnceIsStillNotKnown() {
        let held = stride(from: 11.21, through: 11.29, by: 0.02).map { MediaClock.Sample(wall: $0, media: 4, paused: false, rate: 1) }
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + paused(from: 11.01, to: 11.2, at: 4)
                               + held + [held.last!] + playing(from: 11.31, to: 12, media: 4.11))
        #expect(clock.jumps(over: 0.01).isEmpty)
    }
}
