import Foundation
import Network

/// Whether the Mac can reach a network, for a page that failed for want of
/// one: it opens again once the Mac is back online, as in Chrome.
enum Online {
    private static var wasOnline: Bool?
    private static var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Started at the first wait, and kept: it costs next to nothing.
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated { changed(online) }
        }
        monitor.start(queue: .main)
        return monitor
    }()

    /// Returns when the Mac comes back online from offline. Not at once when
    /// it is online already: a page that failed then would only fail again.
    /// Also when the task waiting is cancelled (its tab closed), so nothing
    /// waits on for a page that is gone.
    static func back() async {
        _ = monitor
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait in
                // Registered in the same turn of the main actor as the cancel
                // check, so the handler below, which hops here, comes after.
                if Task.isCancelled { wait.resume() } else { waiting[id] = wait }
            }
        } onCancel: {
            Task { @MainActor in waiting.removeValue(forKey: id)?.resume() }
        }
    }

    /// What the monitor says, and for tests. The first word counts as back
    /// online too: a page failed for want of a network that is there now.
    static func changed(_ online: Bool) {
        defer { wasOnline = online }
        guard online, wasOnline != true else { return }
        let back = waiting
        waiting = [:]
        for wait in back.values { wait.resume() }
    }
}
