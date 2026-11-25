import Foundation

/// Puts tabs to sleep in every window: the ones unseen longer than
/// Settings › Tabs allows, heavy ones sooner, and under critical memory
/// pressure the heaviest one not in use, one at a time (`pressure`). One for
/// the app, so the rules see all windows at once; for the timer, each
/// window's browser still decides which of its own tabs may sleep
/// (`Browser.sleepIdleTabs`).
final class SleepCoordinator {
    static let shared = SleepCoordinator()

    /// How short the Mac is of memory, as the system reports it.
    enum MemoryPressure { case normal, warning, critical }

    /// Whether Low Power Mode is on, as it last changed.
    private(set) var lowPower = LowPowerMode.isOn

    /// The pressure as last reported.
    private var level = MemoryPressure.normal
    /// While pressure is critical, how long between one tab put to sleep and
    /// the next; tests shorten it.
    var lookEvery: Duration = .seconds(5)
    /// Puts tabs to sleep one at a time while pressure is critical.
    private var relief: Task<Void, Never>?

    private let browsers = NSHashTable<Browser>.weakObjects()
    private var timer: Timer?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?

    /// With `watchingSystem`, the minute's check and the system's memory
    /// pressure; without, as in tests, only what is called.
    init(watchingSystem: Bool = true) {
        LowPowerMode.watch(self) { [weak self] on in self?.lowPower = on }
        guard watchingSystem else { return }
        // Checked each minute, loosely, so the system can fold it in with other wake-ups.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 15
        // Normal too, so relief hears that the pressure is over.
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.pressure(event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
            }
        }
        memoryPressure?.activate()
    }

    isolated deinit {
        timer?.invalidate()
        memoryPressure?.cancel()
        relief?.cancel()
    }

    /// A window's browser, kept only while it lives.
    func register(_ browser: Browser) {
        browsers.add(browser)
    }

    /// The minute's check: tabs unseen past the setting sleep, unless gone
    /// to more than `Browser.revisited` times, and ones taking more than
    /// `Browser.heavy` after `Browser.heavyAfter`, pinned or not.
    func check() {
        let after = TabSleep.current.interval
        let sparing = Speedups.isOn(.pressurePolicy)
        for browser in browsers.allObjects {
            if let after { browser.sleepIdleTabs(unseenFor: after, sparingRevisited: sparing) }
            browser.sleepIdleTabs(unseenFor: Browser.heavyAfter, pinsToo: true, over: Browser.heavy)
        }
    }

    /// Memory pressure as the system reports it, or a test in its place.
    /// A warning puts nothing to sleep: a Mac with little memory sits there
    /// all day, and a short spike shouldn't cost reloads. Critical, the
    /// heaviest tab that may sleep goes, then one more each `lookEvery`
    /// until it ends, so as few tabs as possible load again.
    func pressure(_ level: MemoryPressure) {
        guard Speedups.isOn(.pressurePolicy) else { return sleepAll(level) }
        self.level = level
        guard level == .critical else {
            relief?.cancel()
            relief = nil
            return
        }
        guard relief == nil else { return }
        relief = Task { [weak self, every = lookEvery] in
            while await self?.relieve() == true {
                try? await Task.sleep(for: every)
                if Task.isCancelled { return }
            }
        }
    }

    /// One step of relief: the heaviest tab that may sleep, in any window,
    /// goes to sleep. False once the pressure is no longer critical.
    private func relieve() async -> Bool {
        guard level == .critical else { return false }
        let candidates = browsers.allObjects.flatMap { browser in
            browser.tabs.filter { mayRelieve($0, in: browser) }.map { (browser, $0, $0.memory ?? 0) }
        }.sorted { $0.2 > $1.2 }
        for (browser, tab, _) in candidates {
            guard level == .critical else { return false }
            // Asked of the page (a call, a video playing), so it may have
            // come on screen or been typed in meanwhile.
            guard await !isBusy(tab), !Task.isCancelled, mayRelieve(tab, in: browser) else { continue }
            // No picture for the hover card: it takes memory there is none of.
            tab.sleep()
            break
        }
        return level == .critical
    }

    /// How many of the tabs last used in a window, besides the one on
    /// screen, memory pressure leaves awake.
    static let keepRecent = 5
    /// How long after a tab was last on screen pressure leaves it awake, as
    /// Chrome and DuckDuckGo do.
    static let seenGrace: TimeInterval = 10 * 60
    /// How long after a tab stopped making sound it still counts as heard:
    /// a song between tracks, a call between rings (Chrome's minute).
    static let heardGrace: TimeInterval = 60

    /// Whether memory pressure may put `tab` to sleep. Never the tab on
    /// screen, the last five used in its window (what you go back and forth
    /// between), one seen in the last ten minutes, one heard in the last
    /// minute, or one with changes not sent. Pinned tabs no differently.
    private func mayRelieve(_ tab: Tab, in browser: Browser) -> Bool {
        let now = Date.now
        return tab.id != browser.selectedID && !tab.isAsleep && !tab.hasUnsavedWork && !tab.playsAudio
            && now.timeIntervalSince(tab.lastSeen) >= Self.seenGrace
            && tab.lastHeard.map { now.timeIntervalSince($0) >= Self.heardGrace } ?? true
            && !browser.recent.lazy.filter { $0.id != browser.selectedID }.suffix(Self.keepRecent).contains { $0 === tab }
    }

    /// Whether the page is busy (`Tab.isBusy`), taken as only its changes
    /// say if it doesn't answer soon: a page stuck in a loop never does, and
    /// relief would wait on it while memory runs out.
    private func isBusy(_ tab: Tab) async -> Bool {
        let answer = Answer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task { answer.give(await tab.isBusy()) }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                answer.give(tab.hasUnsavedWork)
            }
        }
    }

    /// The first of two answers, the other let go.
    private final class Answer {
        var continuation: CheckedContinuation<Bool, Never>?
        func give(_ busy: Bool) {
            continuation?.resume(returning: busy)
            continuation = nil
        }
    }

    /// The policy before spec #118 (`NERDA_PRESSURE_POLICY=0`): when the Mac
    /// runs short of memory, every tab out of sight sleeps at once; when it
    /// runs out, as in Safari, pinned ones too.
    private func sleepAll(_ level: MemoryPressure) {
        guard level != .normal else { return }
        for browser in browsers.allObjects {
            // No picture for the hover card: it takes memory there is none of.
            browser.sleepIdleTabs(unseenFor: 0, pinsToo: level == .critical, picturing: false)
        }
    }
}
