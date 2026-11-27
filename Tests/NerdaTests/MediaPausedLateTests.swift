import Testing
@testable import Nerda

/// A pause WebKit made later than its media time says (`MediaPage.Paused.late`),
/// over the timeline of the one a full run failed on (#202's, 2026-11-27):
/// media time held at 1.368530 s for 1.28 s, then at the play 1.432597 s,
/// 64 ms on, and on from there. With the picture gone on to where media
/// time came, it is WebKit's late pause; with anything else, still a jump.
struct MediaPausedLateTests {
    private static let pausedAt = 1.368530

    /// The full run's samples, a few of each stretch: playing, the pause,
    /// paused, the play landing at `landing`, held, and on.
    private func clock(landing: Double = 1.432597) -> MediaClock {
        let playing = [(-0.102, 1.266171), (-0.078, 1.290109), (-0.054, 1.314185), (-0.030, 1.338197), (-0.007, 1.361476)]
            .map { MediaClock.Sample(wall: 10 + $0.0, media: $0.1, paused: false, rate: 1) }
        let paused = [0.001, 0.017, 0.155, 0.178, 0.6, 1.0, 1.258, 1.282]
            .map { MediaClock.Sample(wall: 10 + $0, media: Self.pausedAt, paused: true, rate: 1) }
        let on = landing - 1.432597
        let after = [(1.286, 1.432597), (1.347, 1.434977), (1.369, 1.434977), (1.394, 1.434977), (1.417, 1.505417),
                     (1.442, 1.529744), (1.465, 1.553357), (1.489, 1.577375), (1.514, 1.601744)]
            .map { MediaClock.Sample(wall: 10 + $0.0, media: $0.1 + on, paused: false, rate: 1) }
        return MediaClock(samples: playing + paused + after,
                          marks: [.init(wall: 10, name: "pause"), .init(wall: 11.286, name: "play")])
    }

    /// Frame `from` on show as it paused, `halfWay` half way through (`to`
    /// unless given), `to` as it played again.
    private func paused(_ from: Int, _ to: Int, halfWay: Int? = nil, currentAtPlay: Double = pausedAt) -> MediaPage.Paused {
        MediaPage.Paused(still: .init(frame: from, current: Self.pausedAt), halfWay: .init(frame: halfWay ?? to, current: Self.pausedAt),
                         atPlay: .init(frame: to, current: currentAtPlay))
    }

    @Test func thePictureGoneOnToWhereMediaTimeCameIsWebKitsLatePause() {
        let clock = clock()
        let jumps = clock.jumps(over: MediaClock.tolerance)
        #expect(jumps.count == 1)
        // Frame 41 on show as it paused, 43 (1.433 s) as it played again.
        #expect(paused(41, 43).late(jumps, in: clock) == jumps)
    }

    /// Media Source shows it as the pause takes effect: the picture already
    /// on, and no further after.
    @Test func aPictureAlreadyAheadAsItPausedIsWebKitsLatePauseToo() {
        let clock = clock()
        let jumps = clock.jumps(over: MediaClock.tolerance)
        #expect(paused(44, 44).late(jumps, in: clock) == jumps)
        #expect(paused(44, 44).isLate)
    }

    /// Ahead by under two frames is as late: a picture shown is never ahead
    /// of media time otherwise. Frame 42 (1.400 s) on show at 1.369 s.
    @Test func aPictureJustAheadAsItPausedIsLateToo() {
        let clock = clock()
        #expect(paused(42, 42).late(clock.jumps(over: MediaClock.tolerance), in: clock) == clock.jumps(over: MediaClock.tolerance))
    }

    @Test func withThePictureWhereItPausedItIsAJump() {
        let clock = clock()
        #expect(paused(41, 41).late(clock.jumps(over: MediaClock.tolerance), in: clock).isEmpty)
        #expect(!paused(41, 41).isLate)
    }

    @Test func mediaTimeComingFurtherThanThePictureIsAJump() {
        let clock = clock(landing: 1.55)
        let jumps = clock.jumps(over: MediaClock.tolerance)
        #expect(!jumps.isEmpty)
        #expect(paused(41, 43).late(jumps, in: clock).isEmpty)
    }

    /// Not standing still by half way through: not a pause made late, but
    /// media that never stopped.
    @Test func aPictureStillGoingOnInTheSecondHalfIsAJump() {
        let clock = clock(landing: 1.767)
        let jumps = clock.jumps(over: MediaClock.tolerance)
        #expect(!jumps.isEmpty)
        #expect(paused(41, 53, halfWay: 47).late(jumps, in: clock).isEmpty)
        #expect(!paused(41, 53, halfWay: 47).isLate)
        // Stood still by then, 12 frames on (seen under heavy load), it is late.
        #expect(paused(41, 53).late(jumps, in: clock) == jumps)
    }

    @Test func mediaTimeMovedWhilePausedIsNoLatePause() {
        let clock = clock()
        #expect(paused(41, 43, currentAtPlay: 1.43).late(clock.jumps(over: MediaClock.tolerance), in: clock).isEmpty)
    }
}
