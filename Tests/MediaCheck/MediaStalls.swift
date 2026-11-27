import Foundation

extension MediaClock {
    /// Media time standing still while the media plays, then going on from
    /// where it stood: `lost` seconds of media the wall clock let pass and
    /// the media never played, from `wall` (the last sample before it stood
    /// still) at media time `media`; `after` is the last action marked by
    /// then.
    public struct Stall: Sendable, Equatable, CustomStringConvertible {
        public var wall: Double
        public var media: Double
        public var lost: Double
        public var after: String?

        public init(wall: Double, media: Double, lost: Double, after: String?) {
            self.wall = wall
            self.media = media
            self.lost = lost
            self.after = after
        }

        public var description: String {
            String(format: "%.3f s lost at media %.3f s%@", lost, media, after.map { ", after \($0)" } ?? "")
        }
    }

    /// Every stall of more than `tolerance` seconds.
    ///
    /// A stall is media held while playing, after it was moving with the
    /// wall clock (over the tenth of a second before: at least half as fast,
    /// and no jump), measured a tenth of a second after it moves again, so
    /// a late report that catches up in a step or two loses nothing. So
    /// starting to play (after a pause or at a seek's place) is not a stall:
    /// a start is never instant, and WebKit reports media time late as it
    /// starts (`jumps(over:)`). The wall clock is taken at the slower speed
    /// of each two samples, so changing down is no stall either.
    public func stalls(over tolerance: Double) -> [Stall] {
        let look = 0.1
        var stalls: [Stall] = [], index = 1
        while index < samples.count {
            let before = samples[index - 1], now = samples[index]
            guard !before.paused, !now.paused, now.media - before.media < 0.001 else { index += 1; continue }
            // Held from `before` on: until the first sample it moved or paused at.
            var moved = index
            while moved < samples.count, !samples[moved].paused, samples[moved].media - before.media < 0.001 { moved += 1 }
            defer { index = moved + 1 }
            guard wasMoving(to: index - 1, over: look, tolerance: tolerance), moved < samples.count, !samples[moved].paused else { continue }
            // A tenth of a second on, or as far as it played.
            var settled = moved
            while settled + 1 < samples.count, !samples[settled + 1].paused, samples[settled + 1].wall <= samples[moved].wall + look {
                settled += 1
            }
            let lost = allowed(from: index - 1, to: settled) - (samples[settled].media - before.media)
            if lost > tolerance {
                stalls.append(Stall(wall: before.wall, media: before.media, lost: lost,
                                    after: marks.last { $0.wall <= samples[index].wall }?.name))
            }
        }
        return stalls
    }

    /// Whether the media came to sample `end` moving with the wall clock
    /// over the `look` seconds before, playing all the while.
    private func wasMoving(to end: Int, over look: Double, tolerance: Double) -> Bool {
        var start = end
        while start > 0, samples[end].wall - samples[start].wall < look {
            start -= 1
            if samples[start].paused { return false }
        }
        guard start < end else { return false }
        let went = samples[end].media - samples[start].media, wall = allowed(from: start, to: end)
        return went >= wall / 2 && went <= wall + tolerance
    }

    /// The media time the wall clock let pass from sample `start` to `end`,
    /// at the slower speed of each two samples.
    private func allowed(from start: Int, to end: Int) -> Double {
        guard start < end else { return 0 }
        return (start..<end).reduce(0) { total, at in
            total + (samples[at + 1].wall - samples[at].wall) * min(samples[at].rate, samples[at + 1].rate)
        }
    }
}
