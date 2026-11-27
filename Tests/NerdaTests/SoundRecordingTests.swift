import Foundation
import SoundCheck
import Testing
@testable import Nerda
import MediaCheck

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
    func withoutThePermissionARecordingIsRefusedWithTheReason(permission: SoundRecording.Permission) async {
        let refused = await #expect(throws: SoundRecording.Unavailable.self) {
            try await SoundRecorder.start(permission: permission)
        }
        let reason = refused?.description ?? ""
        #expect(reason.contains("Screen Recording"), "\(reason)")
        #expect(reason.contains(permission == .denied ? "denied" : "not been asked"), "\(reason)")
    }

    /// Not asked for, nothing is recorded and the permission isn't read.
    @Test func recordingIsOnlyMadeWhenAskedFor() {
        #expect(SoundRecording.skipped(environment: [:], permission: { Issue.record("The permission was read"); return .granted })
            == "Sound is recorded only when asked for, with NERDA_RECORD_SOUND=1")
        #expect(SoundRecording.skipped(environment: ["NERDA_RECORD_SOUND": "1"], permission: { .granted }) == nil)
        #expect(SoundRecording.skipped(environment: ["NERDA_RECORD_SOUND": "1"], permission: { .notAsked })?
            .contains("Screen Recording") == true)
    }

    /// The sweep played by a page of an app (`SoundHostApp`), with nothing
    /// done to it, recorded for two seconds from outside the app: it
    /// compares clean, and plays at a volume nobody hears, which is what
    /// keeps it from being heard (screen capture can't keep it from the
    /// speakers). In an app, since screen capture takes a page's sound with
    /// the app it plays in, and the test process is no app to it: recorded
    /// in a hosted window, the page's sound comes back as silence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment[SoundRecording.switchName] == "1",
                   "Sound is recorded only when asked for, with NERDA_RECORD_SOUND=1"))
    func theSweepAPageOfAnAppPlaysIsRecordedClean() async throws {
        if let reason = SoundRecording.skipped() { try Test.cancel(Comment(rawValue: reason)) }
        let server = try MediaServer()
        defer { server.stop() }
        let movie = try await GeneratedMovie.mp4(seconds: 30, sound: .sweep)
        let page = try await server.serve("/page", html: MediaPage.html(source: .src(try await server.serve("/sweep.mp4", movie, type: "video/mp4"))))
        let host = try await SoundHostApp.play(page)
        defer { host.quit() }
        #expect(host.volume <= MediaTestBed.inaudible)
        let recorder = try await SoundRecorder.start(app: host.pid)
        try await waitFor("Two seconds of sound were never recorded") { recorder.heard >= 2 }
        let recording = try await recorder.stop()
        let comparison = SoundComparison(recording, rate: recorder.rate)
        print("Recorded the sweep from a page of an app: \(comparison)")
        #expect(recorder.breaks == [], "Screen capture's delivery broke")
        #expect(comparison.clean, "\(comparison)")
        #expect(comparison.runs.reduce(0) { $0 + $1.end - $1.start } >= 1.99, "\(comparison)")
    }
}
