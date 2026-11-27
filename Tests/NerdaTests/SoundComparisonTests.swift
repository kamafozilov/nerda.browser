import AVFoundation
import SoundCheck
import Testing
import MediaCheck

/// The comparison of a recording with the sweep it should have played
/// (`SoundComparison`), fed with made-up recordings: the sweep with sound
/// left out, silence put in or a stretch heard twice, so each fault and its
/// length is known.
struct SoundComparisonTests {
    @Test func theSweepAsPlayedComparesClean() {
        let recording = Sweep.samples(from: 2, seconds: 1.5, rate: 48_000)
        let comparison = SoundComparison(recording, rate: 48_000)
        #expect(comparison.faults == [])
        #expect(comparison.runs.count == 1)
        #expect(abs((comparison.runs.first?.media ?? 0) - 2) < 0.002)
    }

    /// The recording starting before the sound and ending after it: silence
    /// before the first sound and after the last is no fault.
    @Test func silenceBeforeAndAfterTheSoundIsNoFault() {
        let comparison = SoundComparison(silence(0.3) + sweep(5, 1) + silence(0.4), rate: rate)
        #expect(comparison.clean, "\(comparison)")
        #expect(abs((comparison.runs.first?.start ?? 0) - 0.3) < 0.002)
        #expect(abs((comparison.runs.last?.end ?? 0) - 1.3) < 0.002)
    }

    /// A recording without the sweep in it never compares clean.
    @Test func aRecordingWithoutTheSweepIsNotClean() {
        let tone = (0..<Int(rate)).map { Float(0.05 * sin(2 * .pi * 440 * Double($0) / rate)) }
        #expect(!SoundComparison(silence(1), rate: rate).clean)
        #expect(!SoundComparison(tone, rate: rate).clean)
    }

    /// Sound stopping, and carrying on after 30 ms of silence from where
    /// it stopped, as across a pause and play.
    @Test func silenceInTheSoundIsAGapOfItsLength() throws {
        let recording = sweep(2, 0.6) + silence(0.030) + sweep(2.6, 0.6)
        let comparison = SoundComparison(recording, rate: rate)
        let fault = try #require(comparison.faults.only, "\(comparison)")
        guard case .gap(let at, let media, let length, let lost) = fault else { Issue.record("Not a gap: \(fault)"); return }
        #expect(abs(at - 0.6) < 0.003 && abs(media - 2.6) < 0.003)
        #expect(abs(length - 0.030) < 0.003)
        #expect(abs(lost) < 0.003)
    }

    /// Silence taking the place of 40 ms of sound, as when the sound device
    /// drops what it was given.
    @Test func silenceInPlaceOfSoundIsAGapThatLostItsLength() throws {
        let recording = sweep(2, 0.6) + silence(0.040) + sweep(2.64, 0.6)
        let fault = try #require(SoundComparison(recording, rate: rate).faults.only)
        guard case .gap(_, _, let length, let lost) = fault else { Issue.record("Not a gap: \(fault)"); return }
        #expect(abs(length - 0.040) < 0.003)
        #expect(abs(lost - 0.040) < 0.003)
    }

    /// 25 ms of media left out, the sound going straight on from beyond.
    @Test func soundLeftOutIsASkipOfItsLength() throws {
        let recording = sweep(2, 0.6) + sweep(2.625, 0.6)
        let fault = try #require(SoundComparison(recording, rate: rate).faults.only)
        guard case .skip(let at, let media, let length) = fault else { Issue.record("Not a skip: \(fault)"); return }
        #expect(abs(at - 0.6) < 0.005 && abs(media - 2.6) < 0.005)
        #expect(abs(length - 0.025) < 0.003)
    }

    /// The same where the fast tone starts its second again, so a piece
    /// read across the break also holds the tone's leap down.
    @Test func aSkipAtTheTurnOfASecondIsFoundAsWell() throws {
        let recording = sweep(2.4, 0.6) + sweep(3.02, 0.6)
        let fault = try #require(SoundComparison(recording, rate: rate).faults.only)
        guard case .skip(_, _, let length) = fault else { Issue.record("Not a skip: \(fault)"); return }
        #expect(abs(length - 0.020) < 0.003)
    }

    /// 50 ms of media heard twice.
    @Test func soundHeardTwiceIsARepeatOfItsLength() throws {
        let recording = sweep(2, 0.6) + sweep(2.55, 0.6)
        let fault = try #require(SoundComparison(recording, rate: rate).faults.only)
        guard case .repeat(_, let media, let length) = fault else { Issue.record("Not a repeat: \(fault)"); return }
        #expect(abs(media - 2.6) < 0.005)
        #expect(abs(length - 0.050) < 0.003)
    }

    /// Half a second of media played in 0.51 s, its pitch kept, then on at
    /// its own pace.
    @Test func mediaPlayedSlowerIsAStretchAtItsRate() throws {
        let slower = Sweep.samples(from: 2.5, seconds: 0.51, rate: rate, speed: 0.5 / 0.51)
        let recording = sweep(2, 0.5) + slower + sweep(3, 0.5)
        let faults = SoundComparison(recording, rate: rate).faults
        let stretch = try #require(faults.first { if case .stretch = $0 { true } else { false } }, "\(faults)")
        guard case .stretch(let at, _, let length, let rate) = stretch else { return }
        #expect(abs(at - 0.5) < 0.01 && abs(length - 0.51) < 0.01)
        #expect(abs(rate - 0.5 / 0.51) < 0.002)
        #expect(faults.count == 1)
    }

    /// The sweep as a page gets it: in the bed's movie, through AAC, read
    /// back at the rate and the level a recording would have it, quiet as
    /// the bed plays it. Compared clean from end to end, and with each
    /// fault cut into it found at its length.
    @Test(arguments: [48_000.0, 44_100.0])
    func theSweepThroughTheBedsMovieComparesCleanAndItsFaultsAreFound(rate: Double) async throws {
        let movie = try await GeneratedMovie.mp4(seconds: 3, sound: .sweep)
        let decoded = try await Self.sound(of: movie, rate: rate).map { $0 * 0.001 }
        let whole = SoundComparison(decoded, rate: rate)
        #expect(whole.clean, "\(whole)")
        #expect(abs((whole.runs.first?.media ?? 1) - 0) < 0.003, "The sound doesn't start at media 0: \(whole)")

        let at = Int(1.3 * rate), cut = Int(0.020 * rate)
        let skipped = Array(decoded[..<at] + decoded[(at + cut)...])
        let paused = Array(decoded[..<at] + [Float](repeating: 0, count: cut) + decoded[at...])
        let repeated = Array(decoded[..<at] + decoded[(at - cut)...])
        let found = [skipped, paused, repeated].map { SoundComparison($0, rate: rate).faults }
        #expect(found.map(\.count) == [1, 1, 1], "\(found)")
        if case .skip(_, _, let length) = found[0].first { #expect(abs(length - 0.020) < 0.003) } else { Issue.record("\(found[0])") }
        if case .gap(_, _, let length, let lost) = found[1].first { #expect(abs(length - 0.020) < 0.003 && abs(lost) < 0.003) } else { Issue.record("\(found[1])") }
        if case .repeat(_, _, let length) = found[2].first { #expect(abs(length - 0.020) < 0.003) } else { Issue.record("\(found[2])") }
    }

    /// The movie's sound, decoded as mono floats at `rate`.
    private static func sound(of movie: Data, rate: Double) async throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "sweep-\(UUID().uuidString).mp4")
        try movie.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += floats
        }
        #expect(reader.status == .completed)
        return samples
    }

    private let rate = 48_000.0

    private func sweep(_ media: Double, _ seconds: Double) -> [Float] { Sweep.samples(from: media, seconds: seconds, rate: rate) }

    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }
}

extension Collection {
    /// The one element, or nil when there are none or more.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
