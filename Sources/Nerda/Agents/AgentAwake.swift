import Foundation
import WebKit

/// Agent tabs kept running while their Agent session works: their pages
/// hear nothing of their window being off screen, so WebKit runs them as
/// pages in sight (timers, animation frames, video), and no rule puts them
/// to sleep (`Tab.isKeptAwake`). About two minutes after the session's last
/// request they fall back to the owner's rules. How many Agent tabs stay
/// awake at all is capped by the Mac's memory (`cap`).
@MainActor
final class AgentAwake {
    /// How long after a session's last request its tabs count as working.
    var idleAfter: Duration = .seconds(120)
    /// How many Agent tabs, of every session and profile, stay awake.
    var cap = AgentAwake.cap(memory: ProcessInfo.processInfo.physicalMemory)

    /// About a quarter of the memory in GB, from 6 to 16: 6 on 8 and 16 GB
    /// Macs, 8 on 32, 16 on 64 and up.
    nonisolated static func cap(memory: UInt64) -> Int {
        let gigabytes = Double(memory) / Double(1 << 30)
        return min(16, max(6, Int((gigabytes / 4).rounded())))
    }

    /// Each session's wait for its tabs to fall back, restarted by each request.
    private var resting: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// When each Agent tab was last asked for, to know which went longest unused.
    private var used: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    /// The pages running as in sight, so each is told once, not at every request.
    private let fullSpeed = NSHashTable<WKWebView>.weakObjects()

    /// The session asked for something: its tabs run at full speed, and are
    /// kept from sleep, until it has been idle `idleAfter`.
    func working(_ session: AgentSession, tabs: [AgentTab]) {
        for agentTab in tabs {
            agentTab.tab.isKeptAwake = true
            // A tab new here was opened just now: that is its first use.
            if used[ObjectIdentifier(agentTab.tab)] == nil { used[ObjectIdentifier(agentTab.tab)] = .now }
            if let page = agentTab.tab.page, !fullSpeed.contains(page) { run(page, fully: true) }
        }
        restLater(session, tabs: tabs)
    }

    /// The session's tabs fall back once it has been idle `idleAfter`; a
    /// request still in flight then (a Handoff waiting on the owner) is work.
    private func restLater(_ session: AgentSession, tabs: [AgentTab]) {
        resting[ObjectIdentifier(session)]?.cancel()
        resting[ObjectIdentifier(session)] = Task { [weak self, idleAfter] in
            try? await Task.sleep(for: idleAfter)
            guard !Task.isCancelled, let self else { return }
            if session.working > 0 { restLater(session, tabs: tabs) } else { rest(session, tabs: tabs) }
        }
    }

    /// An agent asked for this tab: awake again if it slept, where it was.
    func use(_ agentTab: AgentTab) {
        let tab = agentTab.tab
        used[ObjectIdentifier(tab)] = .now
        tab.isKeptAwake = true
        if tab.isAsleep { run(tab.webView, fully: true) }
    }

    /// Past the cap, the awake Agent tabs longest unused, of sessions gone
    /// quiet first, go to sleep. One holding something typed stays.
    func keepToCap(_ tabs: [Tab]) {
        let awake = tabs.filter { !$0.isAsleep }
        guard awake.count > cap else { return }
        let now = ContinuousClock.now
        let order = awake.filter { !$0.hasUnsavedWork }.sorted { a, b in
            if a.isKeptAwake != b.isKeptAwake { return !a.isKeptAwake }
            return used[ObjectIdentifier(a), default: now] < used[ObjectIdentifier(b), default: now]
        }
        for tab in order.prefix(awake.count - cap) { tab.sleep() }
        let open = Set(tabs.map(ObjectIdentifier.init))
        used = used.filter { open.contains($0.key) }
    }

    /// `fully`, the page hears nothing of its window being off screen, and
    /// runs as a page in sight; otherwise as any page out of sight. WebKit
    /// looks again only when something about the view changes, so a page
    /// already in its window is hidden and shown again, in the same moment.
    private func run(_ page: WKWebView, fully: Bool) {
        page.hearsWindowCovered(!fully)
        if fully { fullSpeed.add(page) } else { fullSpeed.remove(page) }
        guard page.window != nil, !page.isHidden else { return }
        page.isHidden = true
        page.isHidden = false
    }

    /// The session has gone quiet: its tabs follow the owner's rules again.
    private func rest(_ session: AgentSession, tabs: [AgentTab]) {
        resting[ObjectIdentifier(session)] = nil
        for agentTab in tabs {
            agentTab.tab.isKeptAwake = false
            agentTab.tab.page.map { run($0, fully: false) }
        }
    }
}
