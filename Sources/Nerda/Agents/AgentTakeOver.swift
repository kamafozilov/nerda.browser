import AppKit
import WebKit

/// Take over (GLOSSARY.md): the owner taking an Agent tab they watch into
/// their own hands, by a click or a key in its page, or ⌘.; the agent's
/// calls on it are told so (`AgentError.Code.taken`) until ⌘↩ hands it
/// back. Or they keep it as a tab of their own, and it leaves the agent's
/// session for good.
extension AgentTab {
    /// The owner took it over: not the agent's to use now.
    var isTaken: Bool { agents.taken.contains(tab.id) }
}

extension AgentServer {
    /// What the agent hears asking for a tab the owner took over.
    static func taken(_ tab: AgentTab) -> AgentError {
        AgentError(.taken, """
            The user took over tab \(tab.ref) and is using it now. Your calls on it fail until they hand it \
            back; carry on in another tab, or wait and try it again later.
            """)
    }

    /// The owner's click or key reached `page`: in an Agent tab they watch,
    /// that takes it over. An agent's own input (`AgentInput.isAgents`)
    /// takes nothing, nor the owner's in a tab an agent asked them to do a
    /// step in (a Handoff): that is them doing what was asked, and the agent
    /// carries on after.
    func ownerReached(_ page: WKWebView, with event: NSEvent) {
        guard !AgentInput.isAgents(event), !(page.window is AgentWindow),
              let tab = Self.watched(showing: page), !tab.isTaken, !sessions.waitsOnOwner(tab) else { return }
        takeOver(tab)
    }

    /// The owner takes the Agent tab over.
    func takeOver(_ tab: AgentTab) {
        tab.agents.taken.insert(tab.tab.id)
    }

    /// The owner hands the Agent tab back: its agent's calls on it work again.
    func handBack(_ tab: AgentTab) {
        tab.agents.taken.remove(tab.tab.id)
    }

    /// Whether the owner's window `owner` can keep the Agent tab as theirs:
    /// one of the same browsing (profile, data store) only, so its sign-ins
    /// stay where they are.
    func canKeep(_ tab: AgentTab, in owner: Browser) -> Bool {
        owner.dataStore === tab.agents.browser.dataStore && !owner.isForAgents
            && tab.agents.tabs.contains { $0 === tab.tab }
    }

    /// The owner keeps the Agent tab as a tab of their own, in `owner`'s
    /// list, on screen there: it leaves its session, and the agent asking
    /// for it later is told so. From then it is a tab like the owner's
    /// others, under their sleep rules and kept in their history.
    func keep(_ tab: AgentTab, in owner: Browser) {
        guard canKeep(tab, in: owner) else { return }
        if let session = session(of: tab) {
            sessions.leave(tab, from: session, why: """
                The user kept tab \(tab.ref) as their own tab, so it is no longer yours. Open another with open, \
                or see yours with tabs.
                """)
        }
        for browser in Browser.all where browser.watched?.tab === tab.tab { browser.watched = nil }
        tab.agents.taken.remove(tab.tab.id)
        tab.tab.isKeptAwake = false
        tab.tab.page?.hearsWindowCovered(true)
        tab.agents.browser.move(tab.tab.id, to: owner)
    }

    /// ⌘. takes over the Agent tab watched in the key event's window, ⌘↩
    /// hands back one taken: caught before the page, whatever it does with
    /// them (`AppMenu`). Whether the key was one of these.
    static func ownerKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !AgentInput.isAgents(event),
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              let window = event.window,
              let tab = Browser.all.lazy.compactMap({ $0.watchedTab != nil ? $0.watched : nil })
                  .first(where: { $0.tab.page?.window === window }),
              let server = tab.agents.browser.agentServer else { return false }
        let typed = event.charactersIgnoringModifiers ?? ""
        // By the character, or by the key's place where the layout types none
        // that is Latin (Russian, Uzbek Cyrillic).
        let period = typed == "." || (!typed.allSatisfy(\.isASCII) && event.keyCode == 47)
        let enter = event.keyCode == 36 || event.keyCode == 76
        if period {
            server.takeOver(tab)
            return true
        }
        if enter, tab.isTaken {
            server.handBack(tab)
            return true
        }
        return false
    }

    /// The Agent tab watched in a window of the owner's, with `page` its
    /// page there.
    private static func watched(showing page: WKWebView) -> AgentTab? {
        Browser.all.lazy.compactMap(\.watched).first { $0.tab.page === page }
    }
}
