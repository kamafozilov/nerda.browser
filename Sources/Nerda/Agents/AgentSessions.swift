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
    /// When it last asked for something.
    fileprivate(set) var lastUsed = ContinuousClock.now

    var id: AgentSessionName { name }

    /// What the owner sees it called: Claude for Claude Code, Codex for
    /// Codex, else the client's own name.
    var title: String {
        let client = name.client.lowercased()
        if client.contains("claude") { return "Claude" }
        if client.contains("codex") { return "Codex" }
        return name.client
    }

    fileprivate init(name: AgentSessionName) { self.name = name }
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

    /// The session of that name, made on its first request.
    func session(_ name: AgentSessionName) -> AgentSession {
        let session = all.first { $0.name == name } ?? {
            let session = AgentSession(name: name)
            all.append(session)
            return session
        }()
        session.lastUsed = .now
        return session
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

    /// Closes the session's tab, keeping why for later questions about it.
    func close(_ tab: AgentTab, in session: AgentSession) {
        session.tabs.removeAll { $0.ref == tab.ref }
        ended[tab.ref] = "Tab \(tab.ref) was closed."
        // The agent asked: what it typed there is its own to let go.
        tab.agents.browser.close(tab.tab.id, discarding: true)
    }

    private func isOpen(_ tab: AgentTab) -> Bool { tab.agents.browser.tabs.contains { $0 === tab.tab } }
}
