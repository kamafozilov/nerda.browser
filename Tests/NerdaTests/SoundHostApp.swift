import Foundation
import Testing

/// The small app a recorded page plays in (`Tests/SoundHost`), built from
/// its source as a recording test starts and started behind the windows in
/// use: screen capture takes a page's sound with the app it plays in, and
/// the test process is no app to it. Only for tests that record.
@MainActor
final class SoundHostApp {
    /// Its process, while it plays.
    let pid: pid_t
    /// The page's volume as it started playing.
    let volume: Double
    private let folder: URL

    private init(pid: pid_t, volume: Double, folder: URL) {
        self.pid = pid
        self.volume = volume
        self.folder = folder
    }

    /// Builds the app, starts it with `page`, and returns once the page plays.
    static func play(_ page: URL) async throws -> SoundHostApp {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SoundHost-\(UUID().uuidString)")
        let app = folder.appending(path: "SoundHost.app")
        let binary = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        // A bundle identifier of its own: what makes it an app to screen capture.
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
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "SoundHost/SoundHost.swift")
        try await run("/usr/bin/xcrun", ["swiftc", "-O", "-swift-version", "6", source.path, "-o", binary.appending(path: "SoundHost").path])
        try await run("/usr/bin/codesign", ["--sign", "-", "--force", app.path])
        // Started as the Finder would, but kept in the background.
        let status = folder.appending(path: "status")
        try await run("/usr/bin/open", ["-g", "-n", app.path, "--args", page.absoluteString, status.path])
        var line = ""
        try await waitFor("The sound host never played: \(line)", timeout: .seconds(20)) {
            line = (try? String(contentsOf: status, encoding: .utf8)) ?? ""
            return !line.isEmpty
        }
        let words = line.split(separator: " ")
        guard words.first == "playing", words.count == 3, let pid = pid_t(words[1]), let volume = Double(words[2]) else {
            Issue.record("The sound host didn't play: \(line)")
            throw CancellationError()
        }
        return SoundHostApp(pid: pid, volume: volume, folder: folder)
    }

    /// Quits the app and leaves nothing of it behind.
    func quit() {
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs `tool` off the main thread, and fails with its output unless it
    /// ends well.
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let ended: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(ended == 0, "\(tool) \(arguments.first ?? "") failed: \(said)")
    }
}
