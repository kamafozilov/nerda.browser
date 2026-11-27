import Testing
@testable import Nerda
import MediaCheck

/// Media time standing still while the media plays (`MediaClock.stalls`),
/// over timelines made up here: a stall is time lost against the wall
/// clock, not a report that is late and catches up.
struct MediaStallsTests {
    private func playing(from wall: Double, to end: Double, media: Double, rate: Double = 1, every step: Double = 0.02) -> [MediaClock.Sample] {
        stride(from: wall, through: end, by: step).map {
            MediaClock.Sample(wall: $0, media: media + ($0 - wall) * rate, paused: false, rate: rate)
        }
    }

    private func held(from wall: Double, to end: Double, at media: Double, paused: Bool = false, rate: Double = 1) -> [MediaClock.Sample] {
        stride(from: wall, through: end, by: 0.02).map { MediaClock.Sample(wall: $0, media: media, paused: paused, rate: rate) }
    }

    @Test func mediaRunningWithTheWallClockHasNoStall() {
        #expect(MediaClock(samples: playing(from: 10, to: 12, media: 3)).stalls(over: 0.05).isEmpty)
    }

    /// Media held a fifth of a second while it plays, then going on from
    /// where it stood: that fifth is lost.
    @Test func mediaHeldWhilePlayingIsAStallOfThatLong() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + held(from: 11.02, to: 11.2, at: 4)
                               + playing(from: 11.22, to: 12, media: 4.02),
                               marks: [.init(wall: 11, name: "speed")])
        let stalls = clock.stalls(over: 0.05)
        #expect(stalls.count == 1)
        #expect(abs((stalls.first?.lost ?? 0) - 0.2) <= 0.03)
        #expect(stalls.first?.after == "speed")
    }

    /// Held, then on in one step as far as the wall clock went: the report
    /// was late, nothing was lost.
    @Test func aLateReportThatCatchesUpIsNoStall() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + held(from: 11.02, to: 11.2, at: 4)
                               + playing(from: 11.22, to: 12, media: 4.22))
        #expect(clock.stalls(over: 0.05).isEmpty)
    }

    /// As WebKit reports a start: held where it paused after it plays (a
    /// start is never instant), then on. Starting is not stalling.
    @Test func startingAgainAfterAPauseIsNoStall() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + held(from: 11.02, to: 12, at: 4, paused: true)
                               + held(from: 12.02, to: 12.25, at: 4) + playing(from: 12.27, to: 13, media: 4.1))
        #expect(clock.stalls(over: 0.05).isEmpty)
    }

    /// Nor is the start at a seek's new place.
    @Test func startingAtASeeksPlaceIsNoStall() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3) + held(from: 11.02, to: 11.3, at: 8)
                               + playing(from: 11.32, to: 12, media: 8))
        #expect(clock.stalls(over: 0.05).isEmpty)
    }

    /// A page out of sight samples once a second: media that moved on as far
    /// as the wall clock went is no stall, however far apart the samples.
    @Test func samplesFarApartAreNoStall() {
        #expect(MediaClock(samples: playing(from: 10, to: 20, media: 3, every: 1)).stalls(over: 0.05).isEmpty)
    }

    /// Slower than the speed asked for, from a faster speed to a slower one:
    /// measured at the slower, so changing down is not a stall in itself.
    @Test func changingDownIsNoStall() {
        let clock = MediaClock(samples: playing(from: 10, to: 11, media: 3, rate: 1.5) + playing(from: 11.02, to: 12, media: 4.53))
        #expect(clock.stalls(over: 0.05).isEmpty)
    }
}
