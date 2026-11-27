import Foundation

/// A sound whose pitch tells its media time, for a page to play and a
/// recording of it to be read back (`SoundComparison`): two tones at once.
///
/// - The fast tone climbs from 500 to 4,500 Hz in each second, then starts
///   again: its pitch tells where in the second the media is, to a fraction
///   of a millisecond (4 Hz is a millisecond).
/// - The slow tone climbs 50 Hz a second from 5,000 Hz: its pitch tells
///   which second, for a minute and more.
///
/// Read from its pitch rather than its waveform, the media time holds where
/// the sound is stretched with its pitch kept, as WebKit's time-pitch does.
public enum Sweep {
    /// The fast tone's range in a second, in hertz.
    public static let fast = (low: 500.0, high: 4_500.0)
    /// The slow tone's start and climb, in hertz and hertz a second.
    public static let slow = (low: 5_000.0, climb: 50.0)
    /// Each tone's level, of full scale: together never above 0.1 (−20 dB).
    static let levels = (fast: 0.06, slow: 0.04)

    /// The sound at `media` seconds, from −0.1 to 0.1.
    public static func sample(at media: Double) -> Double {
        let phase = phases(at: media)
        return levels.fast * sin(2 * .pi * phase.fast) + levels.slow * sin(2 * .pi * phase.slow)
    }

    /// `seconds` of the sweep from `media` seconds on, as a recording at
    /// `rate` samples a second would hold it.
    public static func samples(from media: Double, seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sample(at: media + Double($0) / rate)) }
    }

    /// `seconds` of recording of the sweep from `media` on played at
    /// `speed` with its pitch kept, as a time-pitch stretch plays it: each
    /// tone at the pitch of the media time reached, its phase carried on.
    public static func samples(from media: Double, seconds: Double, rate: Double, speed: Double) -> [Float] {
        var fastPhase = phases(at: media).fast, slowPhase = phases(at: media).slow
        return (0..<Int(seconds * rate)).map { index in
            let at = media + Double(index) * speed / rate
            let second = at - at.rounded(.down)
            defer {
                fastPhase += (fast.low + (fast.high - fast.low) * second) / rate
                slowPhase += (slow.low + slow.climb * at) / rate
            }
            return Float(levels.fast * sin(2 * .pi * fastPhase) + levels.slow * sin(2 * .pi * slowPhase))
        }
    }

    /// Each tone's phase at `media`, in cycles.
    private static func phases(at media: Double) -> (fast: Double, slow: Double) {
        // Each second of the fast tone is a whole number of cycles (2,500),
        // so its phase starts again at 0 with the second: no click.
        let second = media - media.rounded(.down)
        return (fast.low * second + (fast.high - fast.low) * second * second / 2,
                slow.low * media + slow.climb * media * media / 2)
    }
}
