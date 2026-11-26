import Foundation
import WebKit

/// The Mac's Low Power Mode (System Settings › Battery), as one input for
/// what follows it: what sleeps, and how hidden pages run. Tests set it for
/// a data store of their own (`force`) and call `changed()` in place of the
/// system, so one test's mode is no other test's.
enum LowPowerMode {
    /// The Mac's mode.
    static var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// The mode for `store`'s pages and spare: a test's, else the Mac's.
    static func isOn(for store: WKWebsiteDataStore) -> Bool {
        forced.object(forKey: store)?.boolValue ?? isOn
    }

    /// On or off for `store`, whatever the Mac's, for tests; nil follows
    /// the Mac again. The pages already open hear of it at `changed()`.
    static func force(_ on: Bool?, for store: WKWebsiteDataStore) {
        if let on { forced.setObject(NSNumber(value: on), forKey: store) } else { forced.removeObject(forKey: store) }
    }

    private static let forced = NSMapTable<WKWebsiteDataStore, NSNumber>.weakToStrongObjects()

    /// Calls `changed` each time the mode is turned on or off, the Mac's or
    /// a store's, for as long as `owner` lives. Each watcher asks the mode
    /// of the stores it has (`isOn(for:)`).
    static func watch(_ owner: AnyObject, _ changed: @escaping () -> Void) {
        _ = observer
        watchers.removeAll { $0.owner == nil }
        watchers.append(Watcher(owner: owner, changed: changed))
    }

    /// Tells every watcher the mode may have changed: the system's notice,
    /// or a test's.
    static func changed() {
        watchers.removeAll { $0.owner == nil }
        for watcher in watchers { watcher.changed() }
    }

    private struct Watcher {
        weak var owner: AnyObject?
        let changed: () -> Void
    }

    private static var watchers: [Watcher] = []

    /// One for every watcher, made with the first.
    private static let observer = NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { changed() }
    }
}
