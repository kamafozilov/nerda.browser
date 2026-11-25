import Foundation

/// The Mac's Low Power Mode (System Settings › Battery), as one input for
/// what follows it: what sleeps, and how hidden pages run. Tests set
/// `forced` and call `changed()` in place of the system.
enum LowPowerMode {
    /// On or off for tests, whatever the Mac's; nil follows the Mac.
    static var forced: Bool?

    static var isOn: Bool { forced ?? ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Calls `changed` with the mode each time it is turned on or off, for
    /// as long as `owner` lives.
    static func watch(_ owner: AnyObject, _ changed: @escaping (Bool) -> Void) {
        _ = observer
        watchers.removeAll { $0.owner == nil }
        watchers.append(Watcher(owner: owner, changed: changed))
    }

    /// Tells every watcher the mode now: the system's notice, or a test's.
    static func changed() {
        watchers.removeAll { $0.owner == nil }
        let on = isOn
        for watcher in watchers { watcher.changed(on) }
    }

    private struct Watcher {
        weak var owner: AnyObject?
        let changed: (Bool) -> Void
    }

    private static var watchers: [Watcher] = []

    /// One for every watcher, made with the first.
    private static let observer = NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { changed() }
    }
}
