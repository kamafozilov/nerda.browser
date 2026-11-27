import Foundation
import SoundCheck

extension LabRun.Sound {
    /// The sound recorded across `action` on the bed's sweep against what
    /// it should have been (`SoundComparison`): sound lost is what the
    /// gaps lost, and what skipped on or was heard again, in ms. At another
    /// speed the sweep's media runs ahead of the recording or behind it,
    /// which reads as skips and repeats: there only the gaps count. Not
    /// measured when the recording holds no sweep.
    public static func compared(_ recording: [Float], rate: Double, action: LabRun.ActionName) -> LabRun.Sound {
        let comparison = SoundComparison(recording, rate: rate)
        guard !comparison.runs.isEmpty else { return .notMeasured("the recording held no sweep (\(comparison))") }
        var lost = 0.0, counted: [SoundComparison.Fault] = []
        for fault in comparison.faults {
            switch fault {
            case .gap(_, _, _, let gone):
                lost += gone
                counted.append(fault)
            case .skip(_, _, let length) where action != .speed:
                lost += length
                counted.append(fault)
            case .repeat(_, _, let length) where action != .speed:
                lost -= length
                counted.append(fault)
            case .stretch where action != .speed:
                counted.append(fault)
            default:
                break
            }
        }
        let loudest = recording.map(abs).max() ?? 0
        let level = loudest > 0 ? String(format: "recorded at %.0f dB of full scale at its loudest", 20 * log10(Double(loudest))) : "recorded silence"
        return .measured(lostMs: (lost * 1000).rounded(), faults: [level] + counted.map(\.description))
    }
}
