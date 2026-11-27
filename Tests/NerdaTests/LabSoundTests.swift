import Lab
import SoundCheck
import Testing

/// How a lab run judges the sound recorded across an action on the bed's
/// sweep (`LabRun.Sound.compared`), fed with made-up recordings: clean,
/// a pause that lost sound, one that heard it twice, and a speed change.
struct LabSoundTests {
    let rate = 48_000.0

    func sweep(_ from: Double, _ seconds: Double) -> [Float] { Sweep.samples(from: from, seconds: seconds, rate: rate) }
    func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    func lost(_ sound: LabRun.Sound) -> Double? {
        if case .measured(let lost, _) = sound { lost } else { nil }
    }

    @Test func aCleanPauseAndPlayLosesNothing() throws {
        let sound = LabRun.Sound.compared(sweep(20, 1) + silence(1) + sweep(21, 1), rate: rate, action: .pauseAndPlay)
        let lost = try #require(lost(sound), "\(sound)")
        #expect(abs(lost) < 3)
    }

    @Test func soundLostAtAPauseIsItsLengthInMilliseconds() throws {
        let sound = LabRun.Sound.compared(sweep(20, 1) + silence(1) + sweep(21.3, 1), rate: rate, action: .pauseAndPlay)
        let lost = try #require(lost(sound), "\(sound)")
        #expect(abs(lost - 300) < 3)
        if case .measured(_, let faults) = sound { #expect(faults.contains { $0.hasPrefix("gap of") }) }
    }

    @Test func soundHeardTwiceIsLostBelowNothing() throws {
        let sound = LabRun.Sound.compared(sweep(20, 1) + silence(1) + sweep(20.8, 1), rate: rate, action: .pauseAndPlay)
        let lost = try #require(lost(sound), "\(sound)")
        #expect(abs(lost + 200) < 3)
    }

    /// At 1.5× the sweep's media runs ahead of the recording, which the
    /// comparison reads as skips: they are the speed, not lost sound.
    @Test func aFasterSpeedIsNoLoss() throws {
        let faster = Sweep.samples(from: 21, seconds: 1, rate: rate, speed: 1.5)
        let sound = LabRun.Sound.compared(sweep(20, 1) + faster + sweep(22.5, 1), rate: rate, action: .speed)
        let lost = try #require(lost(sound), "\(sound)")
        #expect(abs(lost) < 3)
    }

    @Test func aRecordingWithoutTheSweepIsNotMeasured() {
        #expect(lost(LabRun.Sound.compared(silence(2), rate: rate, action: .pauseAndPlay)) == nil)
    }
}
