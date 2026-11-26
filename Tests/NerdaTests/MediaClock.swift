import Foundation

/// A page's media clock read against its wall clock: the element's
/// `currentTime` and the page's `performance.now()`, taken together in the
/// page (`MediaPage.clock(around:)` reads them), so how late Nerda asked
/// for them never enters the numbers. Media time jumps when it moves more
/// than the wall clock let it, or goes back.
struct MediaClock: Sendable {
    /// The clock at one moment of the page: `wall` and `media` in seconds.
    struct Sample: Sendable, Equatable, Decodable {
        var wall: Double
        var media: Double
        var paused: Bool
        var rate: Double
        /// What took it: a media event of the element's (`pause`, `seeked`,
        /// `timeupdate`…) or the page's own ticking (`tick`).
        var event: String = "tick"
    }

    /// An action done to the page, by name, at its wall time: the bed's own
    /// (`pause`, `play`, `seek`) or a test's.
    struct Mark: Sendable, Equatable, Decodable {
        var wall: Double
        var name: String
    }

    /// Media time moving where the wall clock didn't let it: `by` seconds,
    /// forward when positive, back when negative, between the samples at
    /// `wall` and the one before; `after` is the last action marked by then.
    struct Jump: Sendable, Equatable, CustomStringConvertible {
        var wall: Double
        var media: Double
        var by: Double
        var after: String?

        var description: String {
            String(format: "%+.3f s at media %.3f s%@", by, media, after.map { ", after \($0)" } ?? "")
        }
    }

    var samples: [Sample]
    var marks: [Mark] = []

    /// How far media time may stray from the wall clock between two samples
    /// before it counts as a jump.
    static let tolerance = 0.05

    /// Every jump of more than `tolerance` seconds either way. Forward:
    /// media further on than the wall clock let it go since any sample
    /// before, at the faster rate of each two samples, and not at all
    /// between two paused ones. Measured from any sample before, not only
    /// the last, since WebKit reports media time late as it starts playing
    /// (held where it paused, then on in one step, the frames shown running
    /// on all the while): late is not ahead. Back: media going back from one
    /// sample to the next. After a jump, it is measured from where it went.
    func jumps(over tolerance: Double) -> [Jump] {
        guard let first = samples.first else { return [] }
        // `allowed`: the media time the wall clock let pass since the first
        // sample; `lead`: the furthest on a sample so far was, less that.
        var allowed = 0.0, lead = first.media, jumps: [Jump] = []
        for (before, after) in zip(samples, samples.dropFirst()) {
            allowed += before.paused && after.paused ? 0 : (after.wall - before.wall) * max(before.rate, after.rate)
            let ahead = after.media - allowed - lead, back = after.media - before.media
            let by = ahead > tolerance ? ahead : back < -tolerance ? back : nil
            guard let by else {
                lead = max(lead, after.media - allowed)
                continue
            }
            lead = after.media - allowed
            jumps.append(Jump(wall: after.wall, media: before.media, by: by, after: marks.last { $0.wall <= after.wall }?.name))
        }
        return jumps
    }
}
