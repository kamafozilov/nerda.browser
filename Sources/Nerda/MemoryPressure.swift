import Foundation

/// How short the Mac is of memory, as the system reports it, as one input
/// for what lets memory go: tabs put to sleep (SleepCoordinator), pages'
/// last frames (LastFrame) and the new tab's picture (Backdrop).
enum MemoryPressure {
    case normal, warning, critical

    /// Calls `heard` with each level the system reports, for as long as
    /// `owner` lives.
    static func watch(_ owner: AnyObject, _ heard: @escaping (MemoryPressure) -> Void) {
        if hearsSystem { _ = source }
        watchers.removeAll { $0.owner == nil }
        watchers.append(Watcher(owner: owner, heard: heard))
    }

    /// Whether the system's reports reach the watchers: not in a run that
    /// says so with NERDA_SYSTEM_MEMORY_PRESSURE=0, read once, as the tests'
    /// does (TestRun.c), so the Mac being short of memory puts none of their
    /// tabs to sleep or drops their frames.
    static let hearsSystem = ProcessInfo.processInfo.environment["NERDA_SYSTEM_MEMORY_PRESSURE"] != "0"

    private struct Watcher {
        weak var owner: AnyObject?
        let heard: (MemoryPressure) -> Void
    }

    private static var watchers: [Watcher] = []

    /// One for every watcher, made with the first. Normal too, so a watcher
    /// hears that the pressure is over.
    private static let source: any DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let event = source.data
                let level: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                watchers.removeAll { $0.owner == nil }
                for watcher in watchers { watcher.heard(level) }
            }
        }
        source.activate()
        return source
    }()
}
