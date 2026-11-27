import Foundation
import MediaCheck
import SoundCheck

/// The run's first step, before any site: that Nerda Test's pages really
/// play at a thousandth of their volume, shown by a recording, or no site
/// is visited. The bed's sweep plays with its element at 0.001, first at
/// the page's full volume, where it comes out at the bed's level, about
/// 0.0001 of full scale (−80 dB): that shows the recording hears it.
/// Then at the run's page volume, where it must come out at least a
/// hundred times lower. A site's own sound plays at the site's volume,
/// and only the page volume keeps it from being heard.
@MainActor
enum Quiet {
    struct Loud: Error, CustomStringConvertible {
        var description: String
    }

    /// The loudest sample of each recording, of full scale: at the page's
    /// full volume, then at the run's.
    static func check(_ nerda: NerdaTest, _ media: LocalMedia) async throws -> (full: Float, quiet: Float) {
        let url = try await media.quietFile()
        let tab = try await nerda.send("open", ["url": url.absoluteString]) as? Int ?? 0
        defer { Task { _ = try? await nerda.send("close", ["tab": tab]) } }
        let run = { (script: String) in try await nerda.send("run", ["tab": tab, "frame": 0, "script": script], timeout: 30) }
        let deadline = Date().addingTimeInterval(20)
        while try await run(Probe.watch) as? Bool != true {
            guard Date() < deadline else { throw Loud(description: "the quiet check's video never loaded") }
            try await Task.sleep(for: .milliseconds(200))
        }
        func loudest(at volume: Double) async throws -> Float {
            try await nerda.send("volume", ["tab": tab, "value": volume])
            let recorder = try await SoundRecorder.start(app: nerda.pid)
            _ = try await run(Probe.script("""
                if (lab.video.volume > 0.001 || lab.video.muted) throw new Error('the check page is louder than 0.001, or muted');
                await lab.video.play();
                await lab.played(1.5);
                lab.video.pause();
                return true;
                """))
            return try await recorder.stop().map(abs).max() ?? 0
        }
        let full = try await loudest(at: 1)
        let quiet = try await loudest(at: Double(volume))
        return (full, quiet)
    }

    /// What the run's pages play at (`Lab.volume` in Nerda).
    static let volume: Float = 0.001

    /// Heard at the page's full volume: the bed's level, give or take.
    static let heard: Float = 0.00002

    static func decibels(_ level: Float) -> String {
        level > 0 ? String(format: "%.0f dB", 20 * log10(Double(level))) : "silence"
    }
}
