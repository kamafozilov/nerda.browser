import Accelerate
import Foundation

/// A recording of the sweep (`Sweep`) compared with what it should have
/// been: where it leaves the sweep, how, and by how many milliseconds.
///
/// The recording is read 10 ms at a time, every 2.5 ms, each piece's two
/// pitches telling the media time it holds. Pieces whose media time goes on
/// with the recording's own time make a `Run`. Between two runs the sound
/// broke off: silence came between them (`Fault.gap`), media went on
/// further than the recording did (`Fault.skip`) or back (`Fault.repeat`).
/// A run whose media time goes faster or slower than the recording is
/// `Fault.stretch`. Silence before the first run and after the last is
/// only the recording starting early or ending late, not a fault.
public struct SoundComparison: Sendable, Equatable, Codable, CustomStringConvertible {
    /// A stretch of the recording that plays the sweep on without a break:
    /// from `start` to `end` seconds into the recording, `media` the media
    /// time at `start`, going on at `rate` media seconds a recorded second.
    public struct Run: Sendable, Equatable, Codable {
        public var start: Double
        public var end: Double
        public var media: Double
        public var rate: Double

        /// The media time the run holds `seconds` into the recording.
        public func media(at seconds: Double) -> Double { media + rate * (seconds - start) }
    }

    /// Where the recording leaves the sweep, `at` seconds into it, the
    /// sound having got to `media` seconds of media time.
    public enum Fault: Sendable, Equatable, Codable, CustomStringConvertible {
        /// `length` seconds of silence where sound should have been, the
        /// media having moved on `lost` seconds across it: none when the
        /// sound carried on where it stopped, the silence's length when the
        /// silence took the place of sound, less than none when it repeated.
        case gap(at: Double, media: Double, length: Double, lost: Double)
        /// `length` seconds of media left out, with no silence for them.
        case skip(at: Double, media: Double, length: Double)
        /// `length` seconds of media heard twice.
        case `repeat`(at: Double, media: Double, length: Double)
        /// `length` seconds of the recording playing media at `rate`.
        case stretch(at: Double, media: Double, length: Double, rate: Double)

        public var at: Double {
            switch self {
            case .gap(let at, _, _, _), .skip(let at, _, _), .repeat(let at, _, _), .stretch(let at, _, _, _): at
            }
        }

        public var description: String {
            func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
            let place = String(format: "at %.3f s (media %.3f s)", at, {
                switch self {
                case .gap(_, let media, _, _), .skip(_, let media, _), .repeat(_, let media, _), .stretch(_, let media, _, _): media
                }
            }())
            return switch self {
            case .gap(_, _, let length, let lost): "gap of \(ms(length)), \(ms(lost)) of media lost, \(place)"
            case .skip(_, _, let length): "skip of \(ms(length)) \(place)"
            case .repeat(_, _, let length): "repeat of \(ms(length)) \(place)"
            case .stretch(_, _, let length, let rate): String(format: "stretch at rate %.4f for %@ %@", rate, ms(length), place)
            }
        }
    }

    /// The sweep played on without a break, in the order recorded.
    public var runs: [Run]
    /// Every place the recording leaves the sweep by more than `tolerance`.
    public var faults: [Fault]
    /// The recording's length, in seconds.
    public var length: Double

    /// Whether the recording plays the sweep through, from its first sound
    /// to its last, without leaving it.
    public var clean: Bool { faults.isEmpty && !runs.isEmpty }

    public var description: String {
        guard !runs.isEmpty else { return "no sweep heard" }
        let heard = String(format: "media %.3f–%.3f s heard in %.3f s", runs[0].media, runs.last!.media(at: runs.last!.end), length)
        return faults.isEmpty ? "clean: \(heard)" : "\(heard); " + faults.map(\.description).joined(separator: "; ")
    }

    /// How far a break may go, either way, before it counts as a fault: 5 ms.
    public static let tolerance = 0.005

    /// Compares `recording`, `rate` samples a second, with the sweep.
    public init(_ recording: [Float], rate: Double, tolerance: Double = Self.tolerance) {
        length = Double(recording.count) / rate
        let silences = Self.silences(in: recording, rate: rate)
        let pieces = Self.pieces(of: recording, rate: rate, between: silences)
        runs = Self.runs(of: pieces, between: silences, rate: rate, length: length)
        faults = Self.faults(between: runs, tolerance: tolerance)
    }

    // MARK: Silence

    /// The samples, start and end, where the recording is silent for at
    /// least `window` (2 ms, a cycle of both tones at their lowest): every
    /// sample under a quarter of the recording's usual loudness.
    private static let window = 0.002

    private static func silences(in recording: [Float], rate: Double) -> [Range<Int>] {
        let width = max(Int(window * rate), 1)
        guard recording.count >= width else { return recording.isEmpty ? [] : [0..<recording.count] }
        // The loudest sample in each `width` from each sample on.
        let loudness = vDSP.absolute(recording)
        var loudest = [Float](repeating: 0, count: recording.count - width + 1)
        vDSP_vswmax(loudness, 1, &loudest, 1, vDSP_Length(loudest.count), vDSP_Length(width))
        // Usual loudness: the middle of what is at least a tenth of the loudest.
        let top = loudest.max() ?? 0
        let sounding = loudest.filter { $0 >= top / 10 }.sorted()
        let usual = sounding.isEmpty ? 0 : sounding[sounding.count / 2]
        let quiet = max(usual / 4, 1e-9)
        var silences: [Range<Int>] = [], start: Int?
        for (index, level) in loudest.enumerated() {
            if level < quiet {
                start = start ?? index
            } else if let first = start {
                silences.append(first..<index + width - 1)
                start = nil
            }
        }
        if let first = start { silences.append(first..<recording.count) }
        return silences
    }

    // MARK: Pieces

    /// The media time a 10 ms piece of the recording holds, at `seconds`,
    /// its middle, `segment` counting the silences before it.
    private struct Piece {
        var seconds: Double
        var media: Double
        var segment: Int
        var offset: Double { media - seconds }
    }

    private static let pieceLength = 0.010, step = 0.0025, fftOrder = 13

    private static func pieces(of recording: [Float], rate: Double, between silences: [Range<Int>]) -> [Piece] {
        let length = Int(pieceLength * rate), hop = max(Int(step * rate), 1)
        guard length > 0, recording.count >= length else { return [] }
        let spectrum = Spectrum(order: fftOrder, length: length)
        var pieces: [Piece] = [], silence = 0, start = 0
        while start + length <= recording.count {
            let end = start + length
            while silence < silences.count, silences[silence].upperBound <= start { silence += 1 }
            let silent = silence < silences.count && silences[silence].lowerBound < end
            if !silent, let media = spectrum.media(in: recording[start..<end], rate: rate) {
                pieces.append(Piece(seconds: (Double(start) + Double(length) / 2) / rate, media: media, segment: silence))
            }
            start += hop
        }
        return pieces
    }

    // MARK: Runs

    /// How far a piece may lie off its neighbours, or off its run's line,
    /// and still be in it: the pitch read off 10 ms is good to well under a
    /// millisecond.
    private static let fit = 0.002

    private static func runs(of pieces: [Piece], between silences: [Range<Int>], rate: Double, length: Double) -> [Run] {
        // The pieces that go on from each other without a break, each lot
        // with the piece that broke away from it when no silence did.
        var lots: [(pieces: [Piece], brokeAt: Piece?)] = [], lot: [Piece] = [], index = 0
        func agree(from index: Int) -> Bool {
            guard index + 2 < pieces.count else { return false }
            let first = pieces[index]
            return (1...2).allSatisfy {
                pieces[index + $0].segment == first.segment && abs(pieces[index + $0].offset - first.offset) <= fit
            }
        }
        // On from the last few: a stretch moves the offset a hair a piece.
        func goesOn(_ piece: Piece) -> Bool {
            let last = lot.suffix(4)
            return abs(piece.offset - last.map(\.offset).reduce(0, +) / Double(last.count)) <= fit
        }
        while index < pieces.count {
            let piece = pieces[index]
            guard let last = lot.last else {
                if agree(from: index) { lot.append(piece) }
                index += 1
                continue
            }
            guard piece.segment == last.segment else {
                lots.append((lot, nil))
                lot = []
                continue
            }
            if goesOn(piece) {
                lot.append(piece)
                index += 1
                continue
            }
            // A piece that straddles a break, or the turn of the fast tone's
            // second, reads off: dropped when the pieces after it go on.
            let ahead = pieces[(index + 1)..<min(index + 4, pieces.count)]
            if ahead.contains(where: { $0.segment == piece.segment && goesOn($0) }) {
                index += 1
                continue
            }
            lots.append((lot, piece))
            lot = []
        }
        if !lot.isEmpty { lots.append((lot, nil)) }

        // Each lot split where its pace changes, then each part's edges: at
        // a silence, the recording's start or end, halfway to the piece
        // that broke away, or halfway between the two parts of a lot.
        func silenceEnd(before segment: Int) -> Double { segment > 0 ? Double(silences[segment - 1].upperBound) / rate : 0 }
        func silenceStart(after segment: Int) -> Double { segment < silences.count ? Double(silences[segment].lowerBound) / rate : length }
        var runs: [Run] = []
        for (number, lot) in lots.enumerated() {
            let parts = joined(paces(lot.pieces[...]), of: lot.pieces)
            var start = if number > 0, let broke = lots[number - 1].brokeAt {
                (lots[number - 1].pieces.last!.seconds + broke.seconds) / 2
            } else {
                silenceEnd(before: lot.pieces[0].segment)
            }
            for (part, pieces) in parts.enumerated() {
                let end = if part + 1 < parts.count {
                    (pieces.last!.seconds + parts[part + 1].first!.seconds) / 2
                } else if let broke = lot.brokeAt {
                    (pieces.last!.seconds + broke.seconds) / 2
                } else {
                    silenceStart(after: pieces.last!.segment)
                }
                let line = Line(pieces)
                runs.append(Run(start: start, end: max(end, start), media: line.media(at: start), rate: line.rate))
                start = end
            }
        }
        return runs
    }

    /// `pieces` in parts each going at one pace: while one piece lies
    /// further than `fit` off the line through them all, split where two
    /// lines fit them best, each keeping 40 ms of pieces, and so on.
    private static func paces(_ pieces: ArraySlice<Piece>) -> [ArraySlice<Piece>] {
        let least = 16
        guard pieces.count >= 2 * least, let worst = Line(pieces).worst(pieces), worst > fit else { return [pieces] }
        // Sums from the first piece to each, so that each split's two lines
        // and their squares come without going over the pieces again.
        var sums = [Sums()]
        for piece in pieces { sums.append(sums.last!.adding(piece)) }
        func misfit(_ at: Int) -> Double {
            let middle = sums[at - pieces.startIndex]
            return middle.squares + (sums.last!.less(middle)).squares
        }
        let split = (pieces.startIndex + least...pieces.endIndex - least).min { misfit($0) < misfit($1) }!
        return paces(pieces[..<split]) + paces(pieces[split...])
    }

    /// Parts side by side going at nearly one pace joined again: a piece
    /// read off where the fast tone turns its second can split a pace.
    private static func joined(_ parts: [ArraySlice<Piece>], of pieces: [Piece]) -> [ArraySlice<Piece>] {
        var joined: [ArraySlice<Piece>] = []
        for part in parts {
            if let last = joined.last, abs(Line(last).rate - Line(part).rate) < 0.002 {
                joined[joined.count - 1] = pieces[last.startIndex..<part.endIndex]
            } else {
                joined.append(part)
            }
        }
        return joined
    }

    /// What a line through pieces is drawn from, added up.
    private struct Sums {
        var count = 0.0, seconds = 0.0, media = 0.0, secondsSquared = 0.0, mediaSquared = 0.0, products = 0.0

        func adding(_ piece: Piece) -> Sums {
            Sums(count: count + 1, seconds: seconds + piece.seconds, media: media + piece.media,
                 secondsSquared: secondsSquared + piece.seconds * piece.seconds,
                 mediaSquared: mediaSquared + piece.media * piece.media, products: products + piece.seconds * piece.media)
        }

        func less(_ other: Sums) -> Sums {
            Sums(count: count - other.count, seconds: seconds - other.seconds, media: media - other.media,
                 secondsSquared: secondsSquared - other.secondsSquared, mediaSquared: mediaSquared - other.mediaSquared,
                 products: products - other.products)
        }

        /// The sum of the squares of how far the pieces lie off the line
        /// through them by least squares.
        var squares: Double {
            let spread = secondsSquared - seconds * seconds / count
            let together = products - seconds * media / count
            let around = mediaSquared - media * media / count
            return spread > 0 ? max(around - together * together / spread, 0) : max(around, 0)
        }
    }

    /// The line through pieces: media time against the recording's, by
    /// least squares; at a rate of 1 when they span under 20 ms.
    private struct Line {
        let rate: Double, intercept: Double

        init(_ pieces: some Collection<Piece>) {
            let count = Double(pieces.count)
            let seconds = pieces.map(\.seconds).reduce(0, +), media = pieces.map(\.media).reduce(0, +)
            let squares = pieces.map { $0.seconds * $0.seconds }.reduce(0, +)
            let products = pieces.map { $0.seconds * $0.media }.reduce(0, +)
            let span = (pieces.map(\.seconds).max() ?? 0) - (pieces.map(\.seconds).min() ?? 0)
            rate = span < 0.02 ? 1 : (count * products - seconds * media) / (count * squares - seconds * seconds)
            intercept = (media - rate * seconds) / count
        }

        func media(at time: Double) -> Double { intercept + rate * time }

        func off(_ piece: Piece) -> Double { abs(piece.media - media(at: piece.seconds)) }

        /// How far the piece furthest off the line lies.
        func worst(_ pieces: some Collection<Piece>) -> Double? { pieces.map(off).max() }
    }

    // MARK: Faults

    private static func faults(between runs: [Run], tolerance: Double) -> [Fault] {
        var faults: [Fault] = []
        for (before, after) in zip(runs, runs.dropFirst()) {
            let media = before.media(at: before.end), silence = after.start - before.end, lost = after.media - media
            if silence > tolerance {
                faults.append(.gap(at: before.end, media: media, length: silence, lost: lost))
            } else if lost > tolerance {
                faults.append(.skip(at: before.end, media: media, length: lost))
            } else if lost < -tolerance {
                faults.append(.repeat(at: before.end, media: media, length: -lost))
            }
        }
        // Paced off by more than `tolerance` over the run, as a break would be.
        for run in runs where abs(run.rate - 1) * (run.end - run.start) > tolerance {
            faults.append(.stretch(at: run.start, media: run.media, length: run.end - run.start, rate: run.rate))
        }
        return faults.sorted { $0.at < $1.at }
    }
}
