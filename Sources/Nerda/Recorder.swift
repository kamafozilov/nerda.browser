// Adapted from Lag.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import Foundation
import os

/// What "it was slow" was, the last five minutes of it, for a feedback
/// report (Feedback.diagnostics): how long each tab open, switch and close,
/// Back or Forward and page's first paint took, how long a video took to
/// float as its tab was left and to land as it was come back to, and the
/// main thread's hitches of 100 ms or more (Watchdog). Numbers and kinds
/// only, in memory, never written down and never sent but in a report you
/// choose to send.
///
/// Each kind of entry is a fixed ring: adding one is a few stores, never an
/// allocation, and however long Nerda runs the record holds at most the
/// newest few hundred, of which only the last five minutes are read.
/// Nothing here runs on its own: an operation begun is settled by a
/// one-time observer as the main loop next goes to sleep, so with nothing
/// begun and nothing slow the record costs no timer and no wake-up.
///
/// Each operation is also a signpost interval (category "tabs"), so
/// Instruments shows it on its timeline. `NERDA_RECORDER=0` leaves the
/// record empty for a run, to time Nerda with and without it.
final class Recorder {
    static let shared = Recorder()

    enum Kind: String, CaseIterable {
        /// From the click or key to the end of the main loop's pass that
        /// showed it: the work it cost, SwiftUI's update and Core
        /// Animation's commit included.
        case tabOpen, tabSwitch, tabClose
        /// From Back or Forward being asked for to the page on screen,
        /// painted or brought back from WebKit's cache.
        case backForward
        /// From a page starting to load to its first text or picture painted.
        case firstPaint
        /// From the owner leaving a tab whose video Nerda asks to float to
        /// WebKit saying it floats (Picture in Picture).
        case floating
        /// From the owner coming back to a tab whose video floats to WebKit
        /// saying it is back in its page.
        case landing

        var name: String {
            switch self {
            case .tabOpen: "tab open"
            case .tabSwitch: "tab switch"
            case .tabClose: "tab close"
            case .backForward: "back/forward"
            case .firstPaint: "first paint"
            case .floating: "floating"
            case .landing: "landing"
            }
        }
    }

    struct Timing: Equatable {
        let kind: Kind
        let seconds: TimeInterval
        /// How long ago it ended.
        let age: TimeInterval
    }

    struct Hitch: Equatable {
        let seconds: TimeInterval
        let age: TimeInterval
    }

    /// How far back the record reads.
    static let window: TimeInterval = 300
    /// The shortest stop of the main thread kept as a hitch.
    nonisolated static let hitchThreshold: TimeInterval = 0.1

    /// A fixed ring: the newest `capacity`, the oldest overwritten.
    struct Ring<Element> {
        private var slots: [Element?]
        private var next = 0
        private(set) var count = 0
        init(capacity: Int) { slots = Array(repeating: nil, count: capacity) }
        var capacity: Int { slots.count }
        mutating func add(_ element: Element) {
            slots[next] = element
            next = (next + 1) % slots.count
            count = min(count + 1, slots.count)
        }
        /// Oldest first.
        var elements: [Element] {
            (0..<count).compactMap { slots[(next - count + $0 + slots.count) % slots.count] }
        }
    }

    private var timingRing = Ring<(kind: Kind, seconds: TimeInterval, at: TimeInterval)>(capacity: 256)
    private var hitchRing = Ring<(seconds: TimeInterval, at: TimeInterval)>(capacity: 128)
    private let clock: () -> TimeInterval

    /// Seconds since the Mac started, not counting its sleep, as the main
    /// loop doesn't run while the Mac sleeps.
    nonisolated static func uptime() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    init(clock: @escaping () -> TimeInterval = Recorder.uptime) { self.clock = clock }

    private static var isOn: Bool { Speedups.isOn(.recorder) }

    private static let signposter = OSSignposter(subsystem: Logger.subsystem, category: "tabs")

    // MARK: - writing

    /// The operation waiting for the main loop to go to sleep.
    /// Held, it waits for `release` first.
    private var pending: (kind: Kind, start: TimeInterval, interval: OSSignpostIntervalState, held: Bool)?

    /// `kind` began just now: it is timed until the main loop next goes to
    /// sleep, once what it changed is on screen. One begun while another
    /// waits leaves the first: a tab opened is selected too, and the pass
    /// that shows both is the open's.
    func begin(_ kind: Kind) {
        guard pending == nil, Self.isOn else { return }
        pending = (kind, clock(), Self.signposter.beginInterval(kind.signpost), false)
        settleOnSleep()
    }

    /// What was just begun shows only later, once `release` is called: a
    /// tab switch whose page left stays in sight while its video floats.
    /// Whether there was one to hold, not held already.
    func hold() -> Bool {
        guard pending?.held == false else { return false }
        pending?.held = true
        return true
    }

    /// What `hold` held is on screen as the main loop next goes to sleep.
    func release() {
        guard pending?.held == true else { return }
        pending?.held = false
        settleOnSleep()
    }

    private func settleOnSleep() {
        // Once, after Core Animation's commit at the same moment (its order
        // is lower), and in every mode, a drag's or a menu's included.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.settle() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func settle() {
        guard let (kind, start, interval, held) = pending, !held else { return }
        pending = nil
        Self.signposter.endInterval(kind.signpost, interval)
        add(kind, seconds: clock() - start)
    }

    /// `kind` took `seconds`, timed by whoever saw it end: a page's first
    /// paint, or the page Back went to on screen.
    func record(_ kind: Kind, seconds: TimeInterval) {
        guard Self.isOn else { return }
        Self.signposter.emitEvent(kind.signpost, "\(Int(seconds * 1000)) ms")
        add(kind, seconds: seconds)
    }

    private func add(_ kind: Kind, seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        timingRing.add((kind, seconds, clock()))
    }

    /// The main thread stopped for `seconds`, ending just now.
    func hitch(_ seconds: TimeInterval) {
        guard seconds >= Self.hitchThreshold, seconds.isFinite else { return }
        hitchRing.add((seconds, clock()))
    }

    // MARK: - reading

    /// The last five minutes' timings, oldest first.
    func timings() -> [Timing] {
        let now = clock()
        return timingRing.elements.compactMap { entry in
            let age = max(0, now - entry.at)
            return age <= Self.window ? Timing(kind: entry.kind, seconds: entry.seconds, age: age) : nil
        }
    }

    /// The last five minutes' hitches, oldest first.
    func hitches() -> [Hitch] {
        let now = clock()
        return hitchRing.elements.compactMap { entry in
            let age = max(0, now - entry.at)
            return age <= Self.window ? Hitch(seconds: entry.seconds, age: age) : nil
        }
    }
}

// MARK: - the report

extension Recorder {
    /// The record as text for a feedback report, newest first: each kind's
    /// timings in milliseconds, then the hitches with how long ago they
    /// were. Empty with nothing recorded; at most 1 KB, as the report
    /// travels in the address GitHub opens.
    var report: String {
        let timings = timings().reversed()
        var lines: [String] = []
        for kind in Kind.allCases {
            let values = timings.filter { $0.kind == kind }.prefix(30).map { "\(Self.ms($0.seconds))" }
            if !values.isEmpty { lines.append("\(kind.name): \(values.joined(separator: " "))") }
        }
        if !lines.isEmpty { lines.insert("Timings in the last 5 minutes, newest first, in ms:", at: 0) }
        let hitches = hitches().reversed().prefix(20).map { "\(Self.ms($0.seconds)) ms \(Int($0.age)) s ago" }
        if !hitches.isEmpty { lines.append("Main thread hitches, newest first: \(hitches.joined(separator: ", "))") }
        var text = lines.joined(separator: "\n")
        while text.utf8.count > 1024, let cut = text.lastIndex(where: { $0 == " " || $0 == "\n" }) { text = String(text[..<cut]) }
        return text
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int(min(seconds, 86_400) * 1000) }
}

// MARK: - pages

/// A page's first paint and a Back or Forward's arrival, told by the
/// browser as WebKit tells it (Browser's navigation delegate).
extension Recorder {
    /// WebKit's first visually non-empty layout
    /// (`_WKRenderingProgressEventFirstVisuallyNonEmptyLayout`): the page's
    /// first text or picture, the moment Safari counts a page as drawn.
    static let paintEvents: UInt = 1 << 1

    /// What a tab's page is being timed from.
    struct PageTiming {
        /// The load of the page on screen began.
        var loading: TimeInterval?
        /// Back or Forward was asked for.
        var stepping: TimeInterval?
        /// Nerda asked its video to float, or to land, waiting for WebKit's
        /// word (`floated`): one at a time, the newest ask's.
        var presenting: Presenting?
    }

    /// Floating or landing under way: since when, and its signpost interval.
    struct Presenting {
        let kind: Kind
        let start: TimeInterval
        let interval: OSSignpostIntervalState
    }

    /// Longer than this, something else held it up: a page loaded out of
    /// sight, or a Mac asleep.
    private static let longest: TimeInterval = 60

    /// Back or Forward was asked for in `tab`.
    func stepped(_ tab: Tab) { tab.timing.stepping = clock() }

    /// `tab`'s page began to load; timed only on screen, as a page out of
    /// sight may not paint until it is shown.
    func loading(_ tab: Tab, onScreen: Bool) { tab.timing.loading = onScreen ? clock() : nil }

    /// `tab`'s page painted its first text or picture.
    func painted(_ tab: Tab, onScreen: Bool) {
        if let start = tab.timing.loading, onScreen { time(.firstPaint, since: start) }
        tab.timing.loading = nil
        arrived(tab)
    }

    /// `tab`'s page has loaded: Back or Forward, brought back from WebKit's
    /// cache, may have nothing new to paint.
    func arrived(_ tab: Tab) {
        guard let start = tab.timing.stepping else { return }
        tab.timing.stepping = nil
        time(.backForward, since: start)
    }

    /// `tab`'s page failed to load: nothing of the load to time.
    func failed(_ tab: Tab) { tab.timing = PageTiming(presenting: tab.timing.presenting) }

    private func time(_ kind: Kind, since start: TimeInterval) {
        let seconds = clock() - start
        if seconds < Self.longest { record(kind, seconds: seconds) }
    }
}

// MARK: - floating and landing

/// A video floating (Picture in Picture) as the owner leaves its tab, and
/// landing as they come back: timed from Nerda asking to WebKit's word
/// that the video is, or is no longer, floating. A signpost interval each,
/// begun on the ask and ended on the word. An ask WebKit never answers (a
/// tab with no video to float) is let go on the tab's next ask, its close,
/// or past `presentingLongest`, with nothing written.
extension Recorder {
    /// Longer than this from the ask, WebKit's word answers something else.
    static let presentingLongest: TimeInterval = 5

    /// Nerda asked `tab`'s video to float as the owner left it.
    func leaving(_ tab: Tab) { present(.floating, tab) }

    /// The owner came back to `tab`, and Nerda asked its video to land:
    /// timed only when WebKit has said it floats.
    func returning(to tab: Tab) {
        if tab.isFloating { present(.landing, tab) } else { letGo(tab) }
    }

    /// WebKit says `tab`'s video floats, or has landed: the end of the ask
    /// it answers. A word nobody asked for (the page's own button, the
    /// floating window's) is not timed.
    func floated(_ tab: Tab, _ floating: Bool) {
        guard let presenting = tab.timing.presenting, presenting.kind == (floating ? .floating : .landing) else { return }
        tab.timing.presenting = nil
        Self.signposter.endInterval(presenting.kind.signpost, presenting.interval)
        let seconds = clock() - presenting.start
        if seconds <= Self.presentingLongest { add(presenting.kind, seconds: seconds) }
    }

    /// `tab`'s ask goes unanswered: its tab closed, or asked again.
    func letGo(_ tab: Tab) {
        guard let presenting = tab.timing.presenting else { return }
        tab.timing.presenting = nil
        Self.signposter.endInterval(presenting.kind.signpost, presenting.interval, "unanswered")
    }

    private func present(_ kind: Kind, _ tab: Tab) {
        letGo(tab)
        guard Self.isOn else { return }
        // An ID of its own: several tabs' asks can be open at once.
        let interval = Self.signposter.beginInterval(kind.signpost, id: Self.signposter.makeSignpostID())
        tab.timing.presenting = Presenting(kind: kind, start: clock(), interval: interval)
    }
}

private extension Recorder.Kind {
    var signpost: StaticString {
        switch self {
        case .tabOpen: "tab open"
        case .tabSwitch: "tab switch"
        case .tabClose: "tab close"
        case .backForward: "back/forward"
        case .firstPaint: "first paint"
        case .floating: "floating"
        case .landing: "landing"
        }
    }
}
