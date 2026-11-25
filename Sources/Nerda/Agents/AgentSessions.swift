import Foundation
import Observation

/// One Agent's piece of work in Nerda (GLOSSARY.md), from its first request
/// on, holding its Agent tabs. Every connection with the same client and
/// harness session id is the same one (`AgentSessionName`).
@Observable
final class AgentSession: Identifiable {
    let name: AgentSessionName
    /// Its Agent tabs, oldest first.
    fileprivate(set) var tabs: [AgentTab] = []
    /// When it last asked for something, or last had an answer, in awake
    /// time (`AgentSessions.now`).
    fileprivate(set) var lastUsed: SuspendingClock.Instant
    /// Its agent went away (the MCP client closed the shim's input) and
    /// hasn't asked for anything since. Its tabs stay until cleanup.
    fileprivate(set) var isDetached = false
    /// Requests of its being done now: while there are any, it is at work,
    /// however long one takes.
    @ObservationIgnored fileprivate(set) var working = 0

    var id: AgentSessionName { name }

    /// What the owner sees it called: Claude for Claude Code, Codex for
    /// Codex, else the client's own name.
    var title: String {
        let client = name.client.lowercased()
        if client.contains("claude") { return "Claude" }
        if client.contains("codex") { return "Codex" }
        return name.client
    }

    fileprivate init(name: AgentSessionName, at now: SuspendingClock.Instant) {
        self.name = name
        lastUsed = now
    }
}

/// One Agent tab (GLOSSARY.md): a tab of an Agent browser, with the short
/// name agents call it by (t1, t2…). Names are never used twice while Nerda
/// runs, so a closed tab's name never reaches another tab.
struct AgentTab {
    let ref: String
    let tab: Tab
    /// The Agent browser it is in.
    let agents: AgentBrowser
}

/// Every Agent session, and which Agent tab is whose: no session sees or
/// touches another's tabs, and nothing else is a tab to them (the owner's
/// tabs, incognito), since only tabs opened through here have names.
@Observable
final class AgentSessions {
    private(set) var all: [AgentSession] = []
    @ObservationIgnored private var count = 0
    /// Names of tabs closed, and how, to answer with what happened rather
    /// than "no tab".
    @ObservationIgnored private var ended: [String: String] = [:]
    /// Awake time: it stands still while the Mac sleeps, so a night's sleep
    /// is no time unused. Tests move it by hand.
    @ObservationIgnored let now: () -> SuspendingClock.Instant
    /// Whether the owner holds an Agent tab as their own, so cleanup leaves
    /// it alone (`isKept`). Take over (#145) answers it for a tab the owner
    /// has taken or kept; until then no tab is.
    @ObservationIgnored var ownerKeeps: (AgentTab) -> Bool = { _ in false }

    init(now: @escaping () -> SuspendingClock.Instant = { .now }) {
        self.now = now
    }

    /// The session of that name, made on its first request.
    func session(_ name: AgentSessionName) -> AgentSession {
        if let session = all.first(where: { $0.name == name }) { return session }
        let session = AgentSession(name: name, at: now())
        all.append(session)
        return session
    }

    /// The session of that name starting a request: a use, and at work (and
    /// no longer detached) until `finished`.
    func began(_ name: AgentSessionName) -> AgentSession {
        let session = session(name)
        session.working += 1
        session.isDetached = false
        session.lastUsed = now()
        return session
    }

    /// A request of the session's answered: a use too, as a long wait ends.
    func finished(_ session: AgentSession) {
        session.working -= 1
        session.lastUsed = now()
    }

    /// Its agent went away. No use of its tabs: their 15 minutes still count
    /// from the last request. A session never seen stays unmade.
    func detach(_ name: AgentSessionName) {
        all.first { $0.name == name }?.isDetached = true
    }

    /// Makes `tab` one of the session's Agent tabs, named.
    @discardableResult
    func add(_ tab: Tab, in agents: AgentBrowser, to session: AgentSession) -> AgentTab {
        count += 1
        let added = AgentTab(ref: "t\(count)", tab: tab, agents: agents)
        session.tabs.append(added)
        return added
    }

    /// The session's tabs still open, in the order they were opened. A tab
    /// closed some other way (the owner, the page itself) is let go here.
    func tabs(of session: AgentSession) -> [AgentTab] {
        for gone in session.tabs where !isOpen(gone) { ended[gone.ref] = "Tab \(gone.ref) was closed." }
        session.tabs.removeAll { !isOpen($0) }
        return session.tabs
    }

    /// The session's tab named `ref`; another session's, or none, fails.
    func tab(_ ref: String, for session: AgentSession) throws -> AgentTab {
        if let mine = tabs(of: session).first(where: { $0.ref == ref }) { return mine }
        if let ended = ended[ref] { throw AgentError(.noTab, ended + " Open another with open, or see yours with tabs.") }
        if all.contains(where: { $0 !== session && tabs(of: $0).contains { $0.ref == ref } }) {
            throw AgentError(.notYours, "Tab \(ref) belongs to another agent's session; you can't use it. See yours with tabs.")
        }
        throw AgentError(.noTab, "There is no tab \(ref). See yours with tabs.")
    }

    /// Closes the session's tab, keeping `why` for later questions about
    /// it. What was typed there goes too: the agent asked, or cleanup found
    /// nothing typed to keep.
    func close(_ tab: AgentTab, in session: AgentSession, why: String? = nil) {
        session.tabs.removeAll { $0.ref == tab.ref }
        ended[tab.ref] = why ?? "Tab \(tab.ref) was closed."
        tab.agents.browser.close(tab.tab.id, discarding: true)
    }

    private func isOpen(_ tab: AgentTab) -> Bool { tab.agents.browser.tabs.contains { $0 === tab.tab } }
}
