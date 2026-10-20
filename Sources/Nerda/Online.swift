import Network

/// Whether the Mac can reach a network, for a page that failed for want of
/// one: it opens again once the Mac is back online, as in Chrome.
enum Online {
    private static var wasOnline: Bool?
    private static var waiting: [CheckedContinuation<Void, Never>] = []
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
    static func back() async {
        _ = monitor
        await withCheckedContinuation { waiting.append($0) }
    }

    private static func changed(_ online: Bool) {
        defer { wasOnline = online }
        guard online, wasOnline == false else { return }
        let back = waiting
        waiting = []
        for wait in back { wait.resume() }
    }
}
