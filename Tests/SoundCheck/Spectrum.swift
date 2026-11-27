import Accelerate
import Foundation

/// The two pitches of a piece of the sweep, read with a Fourier transform,
/// and the media time they tell. Its buffers are reused piece to piece:
/// one per comparison, never shared.
final class Spectrum {
    private let size: Int, order: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var input: [Float], real: [Float], imaginary: [Float], power: [Float]

    /// For pieces of `length` samples, padded to 2^`order` for finer bins.
    init(order: Int, length: Int) {
        self.order = vDSP_Length(order)
        size = 1 << order
        setup = vDSP_create_fftsetup(self.order, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: length, isHalfWindow: false)
        input = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The media time `piece` holds, or nil when its pitches aren't the
    /// sweep's.
    func media(in piece: ArraySlice<Float>, rate: Double) -> Double? {
        transform(piece)
        let bin = rate / Double(size)
        guard let fast = peak(from: Sweep.fast.low - 50, to: Sweep.fast.high + 50, bin: bin),
              let slow = peak(from: Sweep.slow.low - 50, to: min(rate / 2 - 100, 20_000), bin: bin)
        else { return nil }
        // Where in its second the fast tone is, then which second the slow
        // tone says, to the nearest one that puts it there.
        let second = min(max((fast - Sweep.fast.low) / (Sweep.fast.high - Sweep.fast.low), 0), 1)
        let roughly = (slow - Sweep.slow.low) / Sweep.slow.climb
        return second + (roughly - second).rounded()
    }

    private func transform(_ piece: ArraySlice<Float>) {
        let length = window.count
        input.withUnsafeMutableBufferPointer { input in
            piece.withUnsafeBufferPointer { piece in
                vDSP_vmul(piece.baseAddress!, 1, window, 1, input.baseAddress!, 1, vDSP_Length(length))
            }
            vDSP_vclr(input.baseAddress! + length, 1, vDSP_Length(size - length))
        }
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                input.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, order, FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer { power in
                    vDSP_zvmags(&split, 1, power.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
    }

    /// The loudest pitch from `low` to `high` hertz, between bins by the
    /// parabola through the logarithms of the three around it; nil when
    /// there is nothing there at all. Noise gives pitches all the same,
    /// which no two pieces agree on (`SoundComparison` keeps only those).
    private func peak(from low: Double, to high: Double, bin: Double) -> Double? {
        let first = max(Int(low / bin), 1), last = min(Int(high / bin), power.count - 2)
        guard first < last else { return nil }
        var loudest = first
        for index in first...last where power[index] > power[loudest] { loudest = index }
        guard power[loudest] > 0 else { return nil }
        let before = log(Double(max(power[loudest - 1], .leastNormalMagnitude)))
        let at = log(Double(power[loudest]))
        let after = log(Double(max(power[loudest + 1], .leastNormalMagnitude)))
        let curve = before - 2 * at + after
        let shift = curve < 0 ? 0.5 * (before - after) / curve : 0
        return (Double(loudest) + shift) * bin
    }
}
