import Foundation
import Lab
import SoundCheck

/// The sweep across a pause and play in WebKit with nothing of Nerda's:
/// a bare `WKWebView` in the small app the sound tests record from
/// (Tests/SoundHost), built here as they build it. Not Safari, but
/// Safari's engine as macOS ships it, which tells Nerda's own part in a
/// loss from WebKit's. Its one small window is ordered behind the others,
/// as in the sound tests; it never comes forward or takes the keyboard.
@MainActor
enum WebKitAlone {
    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    static let name = "WebKit alone, a bare WKWebView (not Safari)"

    /// The page plays itself: play (as a click, from the host), two seconds,
    /// pause, a second, play.
    static func page(_ movie: URL) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        <title>The sweep, paused and played</title>
        <video src="\(movie.absoluteString)" playsinline preload="auto" width="320" height="180"></video>
        <script>
        const media = document.querySelector('video');
        media.volume = 0.001;
        const wait = seconds => new Promise(done => setTimeout(done, seconds * 1000));
        const bed = {
            play: async () => {
                media.currentTime = 20;
                await media.play();
                (async () => { await wait(3); media.pause(); await wait(1); await media.play(); })();
            },
        };
        </script>
        """
    }

    static func compare(_ media: LocalMedia, root: URL, recordings: URL) async -> LabRun.Comparison {
        do {
            let (lost, faults) = try await measure(media, root: root, recordings: recordings)
            return LabRun.Comparison(browser: name, sound: .measured(lostMs: lost, faults: faults))
        } catch {
            return LabRun.Comparison(browser: name, sound: .notMeasured("\(error)"))
        }
    }

    private static func measure(_ media: LocalMedia, root: URL, recordings: URL) async throws -> (Double, [String]) {
        if let refused = SoundRecording.skipped(environment: [SoundRecording.switchName: "1"]) { throw Failed(description: refused) }
        let page = try await media.server.serve("/alone.html", html: page(try await media.fileMovie()))
        let folder = FileManager.default.temporaryDirectory.appending(path: "SoundHost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "SoundHost.app")
        let binary = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>dev.nerda.tests.soundhost</string>
            <key>CFBundleExecutable</key><string>SoundHost</string>
            <key>CFBundleName</key><string>SoundHost</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>LSUIElement</key><true/>
            </dict></plist>
            """.write(to: app.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let source = root.appending(path: "Tests/SoundHost/SoundHost.swift")
        guard Shell.run("/usr/bin/xcrun", ["swiftc", "-O", "-swift-version", "6", source.path, "-o", binary.appending(path: "SoundHost").path]) != nil,
              Shell.run("/usr/bin/codesign", ["--sign", "-", "--force", app.path]) != nil else {
            throw Failed(description: "the bare WebKit app didn't build")
        }
        let status = folder.appending(path: "status")
        guard Shell.run("/usr/bin/open", ["-g", "-n", app.path, "--args", page.absoluteString, status.path]) != nil else {
            throw Failed(description: "the bare WebKit app didn't open")
        }
        var line = ""
        let deadline = Date().addingTimeInterval(20)
        while line.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            line = (try? String(contentsOf: status, encoding: .utf8)) ?? ""
        }
        let words = line.split(separator: " ")
        guard words.first == "playing", words.count == 3, let pid = pid_t(words[1]) else {
            throw Failed(description: "the bare WebKit app didn't play: \(line)")
        }
        defer { kill(pid, SIGTERM) }
        let recorder = try await SoundRecorder.start(app: pid)
        try await Task.sleep(for: .seconds(6.5))
        let samples = try await recorder.stop()
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try? Wave.write(samples, rate: 48_000, to: recordings.appending(path: "webkit-alone-pause-and-play.wav"))
        guard case .measured(let lost, let faults) = LabRun.Sound.compared(samples, rate: recorder.rate, action: .pauseAndPlay) else {
            throw Failed(description: "\(LabRun.Sound.compared(samples, rate: recorder.rate, action: .pauseAndPlay))")
        }
        return (lost, faults)
    }
}
