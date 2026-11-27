import Foundation

/// A page's media clock read against its wall clock: the element's
/// `currentTime` and the page's `performance.now()`, taken together in the
/// page (`MediaPage.clock(around:)` reads them), so how late Nerda asked
/// for them never enters the numbers. Media time jumps when it moves more
/// than the wall clock let it, or goes back.
public struct MediaClock: Sendable {
    /// The clock at one moment of the page: `wall` and `media` in seconds.
    public struct Sample: Sendable, Equatable, Codable {
        public var wall: Double
        public var media: Double
        public var paused: Bool
        public var rate: Double
        /// What took it: a media event of the element's (`pause`, `seeked`,
        /// `timeupdate`…) or the page's own ticking (`tick`).
        public var event: String = "tick"

        public init(wall: Double, media: Double, paused: Bool, rate: Double, event: String = "tick") {
            self.wall = wall
            self.media = media
            self.paused = paused
            self.rate = rate
            self.event = event
        }
    }

    /// An action done to the page, by name, at its wall time: the bed's own
    /// (`pause`, `play`, `seek`) or a test's.
    public struct Mark: Sendable, Equatable, Codable {
        public var wall: Double
        public var name: String

        public init(wall: Double, name: String) {
            self.wall = wall
            self.name = name
        }
    }

    /// Media time moving where the wall clock didn't let it: `by` seconds,
    /// forward when positive, back when negative, between the samples at
    /// `wall` and the one before; `after` is the last action marked by then.
    public struct Jump: Sendable, Equatable, CustomStringConvertible {
        public var wall: Double
        public var media: Double
        public var by: Double
        public var after: String?

        public init(wall: Double, media: Double, by: Double, after: String?) {
            self.wall = wall
            self.media = media
            self.by = by
            self.after = after
        }

        public var description: String {
            String(format: "%+.3f s at media %.3f s%@", by, media, after.map { ", after \($0)" } ?? "")
        }
    }

    public var samples: [Sample]
    public var marks: [Mark] = []

    public init(samples: [Sample], marks: [Mark] = []) {
        self.samples = samples
        self.marks = marks
    }

    /// How far media time may stray before it counts as a jump. Measured on
    /// this Mac (2026-11-27), a clean pause and play of a video file strayed
    /// 27 ms at most in 120 rounds, alone and in two full runs side by side:
    /// the step after WebKit's late report of a start, less what the wall
    /// clock let it go since the last time known.
    public static let tolerance = 0.05

    /// Every jump of more than `tolerance` seconds either way.
    ///
    /// Forward: media further on than the wall clock let it go since the
    /// last time known, at the faster rate of each two samples between, and
    /// not at all between two paused ones. Known: a paused sample, or one
    /// taken as the wall clock moved whose media moved at least as far as
    /// the wall clock let it since the one before. Not one held while
    /// playing, or moving slower, since WebKit reports media time late as it
    /// starts playing: held where it paused, then on in one step (measured
    /// 2026-11-27: in about a third of rounds, held 100–250 ms, then 40–96 ms
    /// in one 20 ms step), or, with the page's own sampling held up, in two:
    /// part of the way and still late, then the rest (measured with the page
    /// busy 30 ms in every 50: 22 ms on in 52 ms, 50 ms late, then 101 ms in
    /// the next 52). With its frames watched, WebKit reports them one by
    /// one, without a step, and none missing. Late is not ahead. So as media
    /// starts again, a skip forward no longer than the start was late,
    /// 100–250 ms, is not seen here: the frames shown or the sound itself
    /// tell those. Nor is media slower than the wall clock (a stall) and
    /// then on to make up for it: only what it gains on the wall clock since
    /// it last kept up is a jump.
    ///
    /// Back: media going back from one sample to the next.
    ///
    /// Not back: WebKit taking back its own estimate. As it starts playing
    /// again, WebKit may run media time on from where it held it before it
    /// hears where the media is, then go back to the very time it held, the
    /// same number, hold it again, and go on from where the media truly
    /// started (measured 2026-11-27, WebKit 625.2.8, in a full run and with
    /// other pages drawing hard: 0.4, 8 and 32 ms back in 3 of 340 rounds,
    /// the estimate 22–24 ms ahead of the media). A step back to exactly the
    /// time last held, by no more than `estimateRunsOn`, is that: no jump,
    /// and the time known is again the one known as it held, since both the
    /// estimate and the time it went back to are wrong. Late is not ahead,
    /// and neither is a guess.
    ///
    /// After a jump, media is measured from where it went.
    public func jumps(over tolerance: Double) -> [Jump] {
        guard let first = samples.first else { return [] }
        // `allowed`: the media time the wall clock let pass since the first
        // sample; `known`: the last time known, and `allowed` as it was then;
        // `held`: the last time media stood still at (paused, or a sample
        // playing that didn't move), and the time known then.
        typealias Known = (media: Double, allowed: Double)
        var allowed = 0.0, known: Known = (first.media, 0), jumps: [Jump] = []
        var held: (media: Double, known: Known)?
        for (before, after) in zip(samples, samples.dropFirst()) {
            let step = before.paused && after.paused ? 0 : (after.wall - before.wall) * max(before.rate, after.rate)
            allowed += step
            let ahead = after.media - known.media - (allowed - known.allowed), moved = after.media - before.media
            if let held, moved < 0, after.media == held.media, -moved <= Self.estimateRunsOn * max(before.rate, after.rate) {
                known = held.known
                continue
            }
            if let by = ahead > tolerance ? ahead : moved < -tolerance ? moved : nil {
                jumps.append(Jump(wall: after.wall, media: before.media, by: by, after: marks.last { $0.wall <= after.wall }?.name))
                known = (after.media, allowed)
                held = nil
            } else if after.paused || step > 0 && moved >= step {
                known = (after.media, allowed)
            }
            if after.paused || after.media == before.media { held = (after.media, known) }
        }
        return jumps
    }

    /// Every sample and mark, one a line, wall time in ms from the first
    /// mark: what a failing test shows, so its jumps can be judged after.
    public var record: String {
        let zero = marks.first?.wall ?? samples.first?.wall ?? 0
        let lines = samples.map { (wall: $0.wall, line: String(format: "%+8.1f ms  media %.6f  %@ %@", ($0.wall - zero) * 1000, $0.media, $0.paused ? "paused" : "      ", $0.event)) }
            + marks.map { (wall: $0.wall, line: String(format: "%+8.1f ms  mark %@", ($0.wall - zero) * 1000, $0.name)) }
        return lines.sorted { $0.wall < $1.wall }.map(\.line).joined(separator: "\n")
    }

    /// How far WebKit's estimate may have run on when it takes it back, in
    /// media seconds at speed 1: no further than WebKit was measured late
    /// on a start (100–250 ms), the blind spot this clock has anyway.
    public static let estimateRunsOn = 0.25
}
