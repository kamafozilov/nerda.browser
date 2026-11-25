import Foundation

/// Cleanup: a finished Agent session's tabs don't pile up. A session that
/// has asked for nothing for 15 minutes of awake time is finished, whether
/// its agent went away (detached) or just stopped, since a killed agent
/// never says so. Its tabs close then, except those holding something typed
/// (Nerda's draft protection) and those the owner keeps, which wait for the
/// owner. `AgentServer` sweeps once a minute of awake time.
extension AgentSessions {
    /// How long a session goes unused before its tabs close.
    static let idleLimit: Duration = .seconds(15 * 60)
    /// How often the server looks.
    static let sweepEvery: Duration = .seconds(60)

    /// Closes the tabs of every session unused for `idleLimit`, but those
    /// kept (`isKept`). An agent asking for one later is told it was closed
    /// after its session ended.
    func cleanUp() {
        let time = now()
        for session in all where session.working == 0 && time - session.lastUsed >= Self.idleLimit {
            for tab in tabs(of: session) where !isKept(tab) {
                close(tab, in: session, why: """
                    Tab \(tab.ref) was closed after its session ended: nothing used it for \
                    \(Self.idleLimit.components.seconds / 60) minutes.
                    """)
            }
        }
    }

    /// Whether cleanup leaves the tab alone: it holds something typed that
    /// would be lost (`Tab.hasUnsavedWork`), the owner keeps it
    /// (`ownerKeeps`), or an Agent waits on the owner there
    /// (`waitsOnOwner`). Looked at again each sweep, so a tab closes once
    /// what kept it is dealt with.
    func isKept(_ tab: AgentTab) -> Bool {
        tab.tab.hasUnsavedWork || ownerKeeps(tab) || waitsOnOwner(tab)
    }
}
