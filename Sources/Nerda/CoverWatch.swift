import AppKit

/// While Nerda is in the background, with "Also when switching to another
/// app" on: whether the window left in front is hidden or at least half
/// covered (`WindowCover`), read as Nerda is left and again whenever what
/// covers it may have changed, until its video floats or the owner is back.
/// The window server tells nothing as another app's window is moved over
/// part of it, so besides the moments it does tell of (another app forward,
/// an app hidden or shown, another Space, the screens changed, the window
/// itself hidden or shown), it is read every `every` seconds; only while a
/// video could float, as reading costs nothing until one can.
@MainActor
final class CoverWatch {
    private weak var window: NSWindow?
    private weak var browser: Browser?
    private weak var tab: Tab?
    private let cover: @MainActor (NSWindow) -> WindowCover
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Its video floated: nothing more to watch for.
    private(set) var floated = false

    init(window: NSWindow, browser: Browser, cover: @escaping @MainActor (NSWindow) -> WindowCover) {
        self.window = window
        self.browser = browser
        tab = browser.selected
        self.cover = cover
    }

    /// Reads the cover now, and floats the video if it is out of sight
    /// enough. Whether it floated.
    @discardableResult
    func check() -> Bool {
        guard !floated, let window, let browser, let tab, browser.selected === tab, !tab.isMuted,
              browser.floats(leaving: tab), cover(window).hidesVideo, browser.windowLeft() else { return false }
        floated = true
        stop()
        return true
    }

    /// From now on, also as what covers the window may change.
    func start(every: TimeInterval) {
        guard !floated, timer == nil, let window else { return }
        let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        let moments: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (workspace, NSWorkspace.didActivateApplicationNotification, nil),
            (workspace, NSWorkspace.didHideApplicationNotification, nil),
            (workspace, NSWorkspace.didUnhideApplicationNotification, nil),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification, nil),
            (app, NSApplication.didHideNotification, nil),
            (app, NSApplication.didChangeScreenParametersNotification, nil),
            (app, NSWindow.didChangeOcclusionStateNotification, window),
            (app, NSWindow.didMiniaturizeNotification, window),
        ]
        for (center, name, object) in moments {
            let observer = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.check() }
            }
            observers.append((center, observer))
        }
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
        timer.tolerance = every / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Back in Nerda, or its video floated.
    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    isolated deinit { stop() }

    /// Whether it still reads the cover.
    var isWatching: Bool { timer != nil }
}
