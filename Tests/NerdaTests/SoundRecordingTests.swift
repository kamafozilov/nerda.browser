import Foundation
import SoundCheck
import Testing
import WebKit
@testable import Nerda

/// Recording the sound a page played. Never part of a plain `swift test`:
/// only what decides whether a recording may be made runs there. The
/// recording itself runs when asked for, alone:
///
///     NERDA_RECORD_SOUND=1 swift test --filter SoundRecordingTests
@Suite(.serialized)
@MainActor
struct SoundRecordingTests {
    /// Without the system's permission to record other apps' sound, no
    /// recording is tried, and the reason says why and whose it is.
    @Test(arguments: [SoundRecording.Permission.notAsked, .denied])
    func withoutThePermissionARecordingIsRefusedWithTheReason(permission: SoundRecording.Permission) {
        let refused = #expect(throws: SoundRecording.Unavailable.self) {
            try SoundRecorder(processes: [getpid()], permission: permission)
        }
        let reason = refused?.description ?? ""
        #expect(reason.contains("System Audio Recording"), "\(reason)")
        #expect(reason.contains(permission == .denied ? "denied" : "not been asked"), "\(reason)")
    }

    /// Not asked for, nothing is recorded and the permission isn't read.
    @Test func recordingIsOnlyMadeWhenAskedFor() {
        #expect(SoundRecording.skipped(environment: [:], permission: { Issue.record("The permission was read"); return .granted })
            == "Sound is recorded only when asked for, with NERDA_RECORD_SOUND=1")
        #expect(SoundRecording.skipped(environment: ["NERDA_RECORD_SOUND": "1"], permission: { .granted }) == nil)
        #expect(SoundRecording.skipped(environment: ["NERDA_RECORD_SOUND": "1"], permission: { .notAsked })?
            .contains("System Audio Recording") == true)
    }

    /// The sweep played by a page in a hosted window, with nothing done to
    /// it, recorded for two seconds of media: it compares clean. Skipped,
    /// with the reason, unless asked for and allowed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment[SoundRecording.switchName] == "1",
                   "Sound is recorded only when asked for, with NERDA_RECORD_SOUND=1"))
    func theSweepAPagePlaysIsRecordedClean() async throws {
        if let reason = SoundRecording.skipped() { try Test.cancel(Comment(rawValue: reason)) }
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.file(sound: .sweep))
        let process = try #require(page.tab.webView.gpuProcess, "No GPU process plays the page's sound")
        let recorder = try SoundRecorder(processes: [process])
        _ = try await page.clock(around: {}, before: 0, after: 2)
        let recording = recorder.stop()
        let comparison = SoundComparison(recording, rate: recorder.rate)
        #expect(comparison.clean, "\(comparison)")
        #expect(comparison.runs.reduce(0) { $0 + $1.end - $1.start } > 1.5, "\(comparison)")
    }
}

extension WKWebView {
    /// The process that plays this page's sound, which WebKit shares among
    /// the app's pages: nil when WebKit doesn't say.
    var gpuProcess: pid_t? {
        let selector = NSSelectorFromString("_gpuProcessIdentifier")
        guard responds(to: selector), let pid = (value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
