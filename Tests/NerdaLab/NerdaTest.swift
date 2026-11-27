import AppKit
import CoreGraphics
import Foundation

/// Nerda Test, started for the run with `--lab` and driven through the
/// channel: opened with `open -g`, so macOS never brings it forward, and
/// quit at the end, never leaving a window.
@MainActor
final class NerdaTest {
    static let bundleID = "dev.nerda.browser.test"

    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    let app: URL
    let channel: Channel
    private(set) var pid: pid_t = 0

    init(app: URL, channel: Channel) {
        self.app = app
        self.channel = channel
    }

    /// Nerda Test running already, in this worktree or another: `open`
    /// would give it the run's arguments to ignore, and quitting it would
    /// end someone's work.
    static var alreadyRunning: [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    func start() async throws {
        let address = try await channel.address()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g: not brought forward; -n is not used, a second one is refused before.
        open.arguments = ["-g", app.path, "--args", "--lab", address.absoluteString]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw Failed(description: "open said \(open.terminationStatus)") }
        let deadline = Date().addingTimeInterval(60)
        while channel.pid == nil {
            guard Date() < deadline else { throw Failed(description: "Nerda Test never asked the run what to do") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let hello = try await send("hello") as? [String: Any]
        pid = pid_t(hello?["pid"] as? Int ?? Int(channel.pid ?? 0))
        guard hello?["quiet"] as? Bool == true else {
            throw Failed(description: "WebKit has no way to play Nerda Test's pages quieter (_setMediaVolumeForTesting:)")
        }
    }

    @discardableResult
    func send(_ op: String, _ parameters: [String: Any] = [:], timeout: Double = 30) async throws -> Any {
        try await channel.send(op, parameters, timeout: timeout).value
    }

    /// Quits Nerda Test: asked, then told, then made to.
    func quit() async {
        guard pid > 0 else { return }
        _ = try? await send("quit", timeout: 5)
        for signal in [Int32(0), SIGTERM, SIGKILL] {
            if signal != 0 { kill(pid, signal) }
            let deadline = Date().addingTimeInterval(10)
            while kill(pid, 0) == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if kill(pid, 0) != 0 { return }
        }
    }

    var running: Bool { pid > 0 && kill(pid, 0) == 0 }

    /// Its version, and the commit it was built from.
    var version: String {
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = Shell.run("/usr/bin/git", ["rev-parse", "--short", "HEAD"]) ?? "?"
        let changed = Shell.run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=no"])?.isEmpty == false
        return "Nerda Test \(version) (\(commit)\(changed ? " with changes not committed" : ""))"
    }
}

enum Shell {
    /// What `tool` printed, trimmed; nil if it failed.
    static func run(_ tool: String, _ arguments: [String], log: URL? = nil, in folder: URL? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        let pipe = Pipe()
        if let log, let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        }
        guard (try? process.run()) != nil else { return nil }
        let data = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Looks, every so often, at what the owner would see: which app is in
/// front, and whether any of Nerda Test's windows is on a screen. Either
/// breaks the run's promise; the run stops at the first.
@MainActor
final class Watch {
    let pid: pid_t
    private(set) var checks = 0
    private(set) var broken: [String] = []
    private var task: Task<Void, Never>?
    var onBroken: (() -> Void)?

    init(pid: pid_t) { self.pid = pid }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() { task?.cancel() }

    func check() {
        checks += 1
        var found: [String] = []
        if Self.frontmost() == pid { found.append("Nerda Test was the app in front") }
        let screens = Self.screens()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 2, rect.height > 2 else { continue }
            if screens.contains(where: { $0.intersects(rect) }) {
                found.append("a window of Nerda Test's was on screen at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
            }
        }
        guard !found.isEmpty else { return }
        broken += found
        onBroken?()
    }

    /// The process of the app in front, from Launch Services.
    static func frontmost() -> pid_t? {
        guard let front = Shell.run("/usr/bin/lsappinfo", ["front"]), !front.isEmpty,
              let info = Shell.run("/usr/bin/lsappinfo", ["info", "-only", "pid", front]) else { return nil }
        let digits = info.split(whereSeparator: { !$0.isNumber })
        return digits.last.flatMap { pid_t($0) }
    }

    static func screens() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.map(CGDisplayBounds)
    }

    /// The system's floating windows on screen now (whoever's they are).
    static func floatingWindows() -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { $0[kCGWindowOwnerName as String] as? String == "Picture in Picture" }.count
    }
}

enum NSRunningApplicationList {
    static func with(_ bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
