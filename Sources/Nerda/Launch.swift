// Adapted from Startup.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import AppKit
import Darwin
import os

/// How long each launch takes, from the moment the kernel started Nerda's
/// process, so the time before Nerda's first line counts too, as it does
/// for someone waiting for the window. The moments: main (main.swift's
/// first line), launched (AppKit done launching), window (the first pass
/// of the run loop with the window in, its first frame sent), shown (the
/// window server says it is on screen, which a window behind others never
/// says) and page (the first text or picture a page drew in the tab on
/// screen, WebKit's first paint, as the Recorder times it).
///
/// Every launch keeps its moments, a handful of numbers, with the five
/// launches before it; a feedback report carries them (`report`,
/// Feedback.diagnostics), and nothing else does. Each stage of the launch
/// (`stage`) is an interval on Instruments' os_signpost track (category
/// "launch"), each moment an event on it.
///
/// Work the first window doesn't need waits (`later`) until the first
/// page shows, until the window is up when there is no page to wait for,
/// or three seconds after the window when the page never draws, and then
/// runs one piece per turn of the run loop, never while something is
/// dragged or scrolled. NERDA_LAUNCH_LATER=0 runs it where it is asked
/// for instead, to time a launch with and without it (`Speedups`).
enum Launch {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "dev.nerda.browser", category: "launch")

    /// This launch's record: Nerda's own once `start()` has run, kept with
    /// the launches before it. Tests make records of their own.
    private(set) static var current = Record()

    /// main.swift's first line.
    static func start() {
        current = Record(keepingIn: .standard)
        current.mark("main")
    }

    static func mark(_ name: String) { current.mark(name) }

    @discardableResult
    static func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T { try current.stage(name, body) }

    static func later(_ name: String, _ work: @escaping () -> Void) {
        guard Speedups.isOn(.launchLater) else { return current.stage("later " + name, work) }
        current.later(name, work)
    }

    /// The launch window: its first frame and its showing. Without a page
    /// to load in it, the work that waits starts once it is up.
    static func watch(_ window: NSWindow, waitingForPage: Bool) { current.watch(window, waitingForPage: waitingForPage) }

    static var report: String { current.report }

    /// When the kernel started this process, in the clock `Date` keeps.
    static let processStart: Date = {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&query, 4, &process, &size, nil, 0) == 0 else { return .now }
        let start = process.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }()

    /// One launch: its moments and stages, and the work waiting for it to end.
    final class Record {
        struct Moment {
            let name: String
            /// From the process start for a moment; how long, for a stage.
            let ms: Int
        }

        private(set) var moments: [Moment] = []
        private(set) var stages: [Moment] = []
        /// Whether the work that waits waits for a page, or only the window.
        var waitsForPage = true

        private let start: Date
        private let defaults: UserDefaults?
        /// How long a page that never loads holds the work up, once the window is up.
        private let pageWait: TimeInterval
        private var waiting: [(name: String, work: () -> Void)] = []
        private var begun = false
        private var turnAsked = false
        private var passes: CFRunLoopObserver?
        private var showing: NSObjectProtocol?

        private static let keptKey = "launch.moments"
        /// Kept besides this launch: enough to see a launch get slower.
        private static let keptBefore = 5

        init(start: Date = Launch.processStart, keepingIn defaults: UserDefaults? = nil, pageWait: TimeInterval = 3) {
            self.start = start
            self.defaults = defaults
            self.pageWait = pageWait
        }

        /// The first time `name` happens; later ones aren't the launch's.
        func mark(_ name: String) {
            guard !moments.contains(where: { $0.name == name }) else { return }
            let ms = Int((Date.now.timeIntervalSince(start) * 1000).rounded())
            moments.append(Moment(name: name, ms: ms))
            Launch.signposter.emitEvent("moment", "\(name, privacy: .public) \(ms) ms")
            keep()
            switch name {
            case "page":
                Logger.launch.notice("\(self.line, privacy: .public)")
                beginLater()
            case "window" where !waitsForPage:
                beginLater()
            case "window":
                DispatchQueue.main.asyncAfter(deadline: .now() + pageWait) { [weak self] in self?.beginLater() }
            default: break
            }
        }

        /// `body`, timed as the launch stage `name`.
        @discardableResult
        func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let state = Launch.signposter.beginInterval("stage", id: Launch.signposter.makeSignpostID(), "\(name, privacy: .public)")
            let began = ContinuousClock.now
            defer {
                Launch.signposter.endInterval("stage", state)
                stages.append(Moment(name: name, ms: Int(((ContinuousClock.now - began) / .milliseconds(1)).rounded())))
            }
            return try body()
        }

        /// `work`, once the first page shows: one piece per turn of the run
        /// loop, in the order asked for. Once the launch is over, on the
        /// next turn.
        func later(_ name: String, _ work: @escaping () -> Void) {
            waiting.append((name, work))
            if begun { askTurn() }
        }

        private func beginLater() {
            guard !begun else { return }
            begun = true
            askTurn()
        }

        /// A timer due now runs on the run loop's next pass, not this one,
        /// and only in its default mode: never in a drag, a scroll or a menu.
        private func askTurn() {
            guard !turnAsked, !waiting.isEmpty else { return }
            turnAsked = true
            let turn = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.runNext() }
            }
            RunLoop.main.add(turn, forMode: .default)
        }

        private func runNext() {
            turnAsked = false
            guard !waiting.isEmpty else { return }
            let next = waiting.removeFirst()
            stage("later " + next.name, next.work)
            askTurn()
        }

        func watch(_ window: NSWindow, waitingForPage: Bool) {
            waitsForPage = waitingForPage
            guard passes == nil else { return }
            let passes = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] observer, _ in
                MainActor.assumeIsolated {
                    guard let self, window.isVisible else { return }
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                    self.mark("window")
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), passes, .commonModes)
            self.passes = passes
            if window.isVisible, window.occlusionState.contains(.visible) { return mark("shown") }
            showing = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, window.occlusionState.contains(.visible) else { return }
                    self.mark("shown")
                    if let showing = self.showing { NotificationCenter.default.removeObserver(showing) }
                    self.showing = nil
                }
            }
        }

        /// This launch, on one line: "2026-11-25 14:03 · 0.0.22 · main 85 · launched 210 · …".
        var line: String {
            ([Self.day.string(from: start), Updater.current] + moments.map { "\($0.name) \($0.ms)" }).joined(separator: " · ")
        }

        /// This launch and the ones kept before it, newest first, and what
        /// this one's stages held the main thread.
        var report: String {
            guard !moments.isEmpty || !stages.isEmpty else { return "" }
            var lines = ["Launches, in ms from the process start, newest first:", line]
            if !stages.isEmpty {
                lines.append("  stages: " + stages.map { "\($0.name) \($0.ms)" }.joined(separator: " · "))
            }
            lines += kept.filter { $0.start != start.timeIntervalSince1970 }.prefix(Self.keptBefore).map(\.line)
            return lines.joined(separator: "\n")
        }

        private var kept: [(start: Double, line: String)] {
            (defaults?.array(forKey: Self.keptKey) as? [[String: Any]] ?? []).compactMap { entry in
                guard let start = entry["start"] as? Double, let line = entry["line"] as? String else { return nil }
                return (start, line)
            }
        }

        private func keep() {
            guard let defaults else { return }
            let mine = start.timeIntervalSince1970
            let entries = ([(mine, line)] + kept.filter { $0.start != mine })
                .sorted { $0.start > $1.start }
                .prefix(Self.keptBefore + 1)
                .map { ["start": $0.start, "line": $0.line] as [String: Any] }
            defaults.set(Array(entries), forKey: Self.keptKey)
        }

        private static let day: DateFormatter = {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd HH:mm"
            return format
        }()
    }
}
