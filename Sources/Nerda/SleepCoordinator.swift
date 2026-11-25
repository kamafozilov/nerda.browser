import Foundation

/// Puts tabs to sleep in every window: the ones unseen longer than
/// Settings › Tabs allows, heavy ones sooner, and under memory pressure
/// every one out of sight. One for the app, so the rules see all windows
/// at once; each window's browser still decides which of its own tabs may
/// sleep (`Browser.sleepIdleTabs`).
final class SleepCoordinator {
    static let shared = SleepCoordinator()

    /// How short the Mac is of memory, as the system reports it.
    enum MemoryPressure { case normal, warning, critical }

    /// Whether Low Power Mode is on, as it last changed.
    private(set) var lowPower = LowPowerMode.isOn

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
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.pressure(event.contains(.critical) ? .critical : .warning)
            }
        }
        memoryPressure?.activate()
    }

    isolated deinit {
        timer?.invalidate()
        memoryPressure?.cancel()
    }

    /// A window's browser, kept only while it lives.
    func register(_ browser: Browser) {
        browsers.add(browser)
    }

    /// The minute's check: tabs unseen past the setting sleep, and ones
    /// taking more than `Browser.heavy` after `Browser.heavyAfter`, pinned or not.
    func check() {
        let after = TabSleep.current.interval
        for browser in browsers.allObjects {
            if let after { browser.sleepIdleTabs(unseenFor: after) }
            browser.sleepIdleTabs(unseenFor: Browser.heavyAfter, pinsToo: true, over: Browser.heavy)
        }
    }

    /// When the Mac runs short of memory, every tab out of sight sleeps at
    /// once; when it runs out, as in Safari, pinned ones too.
    func pressure(_ level: MemoryPressure) {
        guard level != .normal else { return }
        for browser in browsers.allObjects {
            // No picture for the hover card: it takes memory there is none of.
            browser.sleepIdleTabs(unseenFor: 0, pinsToo: level == .critical, picturing: false)
        }
    }
}
