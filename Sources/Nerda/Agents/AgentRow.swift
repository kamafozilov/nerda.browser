import SwiftUI

/// What the Agent row (GLOSSARY.md) and its panel show at one moment: the
/// Agent sessions needing the owner, those at work, and the rest, earlier.
struct AgentActivity {
    enum State {
        /// An Agent waits on the owner: a Handoff, a question.
        case needsYou
        /// Agents are at work.
        case atWork
        /// None is at work, but Agent tabs are still open.
        case idle
    }

    /// Waiting on the owner, the longest waiting first.
    var needsYou: [AgentSession] = []
    /// At work, the one heard from last first.
    var atWork: [AgentSession] = []
    /// Stopped, gone, or quiet a while, the one heard from last first.
    var earlier: [AgentSession] = []
    /// The row's state; nil when it doesn't show.
    var state: State?
    /// What the row says: "Claude", "3 agents", "Claude needs you".
    var title = ""
}

extension AgentServer {
    /// How long after its last request a session still counts as at work.
    static let atWorkFor: Duration = .seconds(120)

    /// What the Agent row shows now. Changes to sessions, tabs and what
    /// waits on the owner are observed; time going by isn't, so the row
    /// looks again now and then.
    func activity() -> AgentActivity {
        let now = sessions.now()
        var activity = AgentActivity()
        activity.needsYou = owner.sessions.filter { !$0.isStopped }
        // The one heard from last first; of two at once, the newer.
        let latest = sessions.all.enumerated().sorted {
            $0.element.lastUsed != $1.element.lastUsed ? $0.element.lastUsed > $1.element.lastUsed : $0.offset > $1.offset
        }.map(\.element)
        for session in latest where !activity.needsYou.contains(where: { $0 === session }) {
            let busy = session.working > 0 || now - session.lastUsed < Self.atWorkFor
            if busy, !session.isStopped, !session.isDetached {
                activity.atWork.append(session)
            } else {
                activity.earlier.append(session)
            }
        }
        if let first = activity.needsYou.first {
            activity.state = .needsYou
            activity.title = activity.needsYou.count == 1 ? "\(first.title) needs you"
                : "\(activity.needsYou.count) agents need you"
        } else if !activity.atWork.isEmpty {
            activity.state = .atWork
            activity.title = Self.names(activity.atWork)
        } else {
            let left = activity.earlier.filter { !openTabs(of: $0).isEmpty }
            if !left.isEmpty {
                activity.state = .idle
                activity.title = Self.names(left)
            }
        }
        return activity
    }

    /// "Claude" for one session, "3 agents" for more.
    private static func names(_ sessions: [AgentSession]) -> String {
        sessions.count == 1 ? sessions[0].title : "\(sessions.count) agents"
    }

    /// The session's tabs still open, oldest first. Unlike
    /// `AgentSessions.tabs(of:)`, it changes nothing, so a view may ask.
    func openTabs(of session: AgentSession) -> [AgentTab] {
        session.tabs.filter { agentTab in agentTab.agents.tabs.contains { $0 === agentTab.tab } }
    }

    /// The session with the Agent tab, if any.
    func session(of tab: AgentTab) -> AgentSession? {
        sessions.all.first { $0.tabs.contains { $0.ref == tab.ref } }
    }

    /// Shows the Agent tab in the owner's window `owner`, over their own
    /// tab, as they watch the agent at work. It stays the agent's. A tab
    /// is watched in one window at a time.
    func watch(_ tab: AgentTab, in owner: Browser) {
        for other in Browser.all where other !== owner && other.watched?.tab === tab.tab { other.watched = nil }
        owner.watched = tab
    }

    /// Shows a request's Agent tab in the window the owner used last, as
    /// they click its notification.
    func show(_ request: OwnerRequest) {
        guard let tab = request.tab, let owner = ownerWindow() else { return }
        watch(tab, in: owner)
    }

    /// Closes the session's Agent tabs, as the owner asked; its agent is
    /// told so if it asks for one.
    func closeTabs(of session: AgentSession) {
        for tab in sessions.tabs(of: session) {
            sessions.close(tab, in: session, why: "Tab \(tab.ref) was closed by the user.")
        }
    }
}

/// The row at the sidebar's foot (GLOSSARY.md: Agent row): which agents are
/// at work, or that one needs the owner, opening a panel of them all. Shown
/// only while there is something to show, and never in incognito windows,
/// which agents don't see.
struct AgentRow: View {
    let browser: Browser
    var server: AgentServer = .shared
    /// The small one of the tabs across the top: an icon and a few words.
    var compact = false

    var body: some View {
        // Sessions and requests are observed; time going by, which ends
        // being at work, is looked at every few seconds.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            AgentRowButton(browser: browser, server: server, compact: compact)
        }
    }
}

/// The Agent row as it is now, and its panel.
struct AgentRowButton: View {
    let browser: Browser
    let server: AgentServer
    let compact: Bool

    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        let activity = server.activity()
        if let state = activity.state, !browser.isPrivate {
            Button { shown.toggle() } label: {
                if compact { small(activity, state) } else { row(activity, state) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering = $0 }
            .help("Agents")
            .accessibilityLabel(activity.title)
            .popover(isPresented: $shown, arrowEdge: compact ? .bottom : .top) {
                AgentPanel(browser: browser, server: server) { shown = false }
                    .popoverGlass()
            }
            .transition(Motion.moving(.move(edge: .bottom).combined(with: .opacity)))
        }
    }

    private func row(_ activity: AgentActivity, _ state: AgentActivity.State) -> some View {
        let watching = browser.watchedTab != nil
        return HStack(spacing: 10) {
            AgentMark(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail(activity, state))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering || shown ? Palette.ink : Palette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(watching ? Palette.wash : hovering || shown ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func small(_ activity: AgentActivity, _ state: AgentActivity.State) -> some View {
        HStack(spacing: 6) {
            AgentMark(state: state, size: 18)
            Text(activity.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering || shown ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
    }

    private func detail(_ activity: AgentActivity, _ state: AgentActivity.State) -> String {
        switch state {
        case .needsYou:
            // The agent's own words, when it asks one thing.
            let requests = server.owner.waiting.filter { !$0.session.isStopped }
            return requests.count == 1 ? requests[0].text : "\(requests.count) things wait for you"
        case .atWork:
            let tabs = activity.atWork.reduce(0) { $0 + server.openTabs(of: $1).count }
            return tabs == 1 ? "At work in 1 tab" : "At work in \(tabs) tabs"
        case .idle:
            return "Done for now"
        }
    }
}

/// The Agent row's mark: a hand while an agent needs the owner, sparkles
/// while agents work (pulsing), and plain sparkles when they're idle.
private struct AgentMark: View {
    let state: AgentActivity.State
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: state == .needsYou ? "hand.raised.fill" : "sparkles")
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(state == .idle ? Palette.muted : .white)
            .symbolEffect(.pulse, isActive: state == .atWork && !Motion.reduced)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .needsYou: AnyShapeStyle(Color.orange.gradient)
        case .atWork: AnyShapeStyle(Color.accentColor.gradient)
        case .idle: AnyShapeStyle(Palette.hover)
        }
    }
}

/// The Agent row's panel: the sessions needing the owner, at work and
/// earlier, each with its Agent tabs, any of which the owner opens in this
/// window to watch; Stop for one at work, and Close for its tabs.
struct AgentPanel: View {
    let browser: Browser
    let server: AgentServer
    let dismiss: () -> Void

    /// Earlier sessions beyond this many aren't listed.
    private static let earlierShown = 8

    var body: some View {
        let activity = server.activity()
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if activity.needsYou.isEmpty, activity.atWork.isEmpty, activity.earlier.isEmpty {
                    Text("No agents have used Nerda yet.")
                        .foregroundStyle(Palette.muted)
                        .padding(10)
                }
                section("Needs you", activity.needsYou, .needsYou)
                section("At work", activity.atWork, .atWork)
                section("Earlier", Array(activity.earlier.prefix(Self.earlierShown)), .idle)
            }
            .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ title: String, _ sessions: [AgentSession], _ state: AgentActivity.State) -> some View {
        if !sessions.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            ForEach(sessions) { session in
                SessionBlock(session: session, state: state, browser: browser, server: server, dismiss: dismiss)
            }
        }
    }
}

/// One Agent session in the panel: its name and state, what it waits on
/// the owner for, its tabs, and Stop and Close.
private struct SessionBlock: View {
    let session: AgentSession
    let state: AgentActivity.State
    let browser: Browser
    let server: AgentServer
    let dismiss: () -> Void

    var body: some View {
        let tabs = server.openTabs(of: session)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(status(tabs: tabs.count))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if state != .idle, !session.isStopped {
                    PanelButton(title: "Stop") { server.stop(session) }
                        .help("Stop \(session.title): it is told you stopped it")
                }
                if !tabs.isEmpty {
                    PanelButton(title: "Close") { server.closeTabs(of: session) }
                        .help(tabs.count == 1 ? "Close its tab" : "Close its \(tabs.count) tabs")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            ForEach(server.owner.waiting.filter { $0.session === session }) { request in
                RequestLine(request: request, owner: server.owner)
            }
            ForEach(tabs, id: \.ref) { tab in
                AgentTabRow(tab: tab, watched: browser.watchedTab === tab.tab) {
                    server.watch(tab, in: browser)
                    dismiss()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func status(tabs: Int) -> String {
        let count = tabs == 0 ? "no tabs open" : tabs == 1 ? "1 tab" : "\(tabs) tabs"
        let doing = switch state {
        case .needsYou: "Waiting for you"
        case .atWork: "At work"
        case .idle: session.isStopped ? "Stopped" : session.isDetached ? "Finished" : "Idle"
        }
        return "\(doing) · \(count)"
    }
}

/// What a session waits on the owner for, with its answers: Done (and
/// Skip) for a Handoff, the choices for a question.
private struct RequestLine: View {
    let request: OwnerRequest
    let owner: OwnerRequests

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if request.isHandoff {
                    if request.canSkip { PanelButton(title: "Skip") { owner.skip(request) } }
                    PanelButton(title: "Done", prominent: true) { owner.done(request) }
                } else {
                    ForEach(Array(request.choices.enumerated()), id: \.offset) { choice in
                        PanelButton(title: choice.element) { owner.pick(request, choice.offset) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
    }
}

/// An Agent tab in the panel: its site's icon, title and site; a click shows
/// it in this window.
private struct AgentTabRow: View {
    let tab: AgentTab
    /// On screen in this window now.
    let watched: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                TabIcon(site: tab.tab.url, loading: tab.tab.isLoading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.tab.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                    if let site = tab.tab.url.flatMap(History.site(of:)) {
                        Text(site)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .opacity(hovering || watched ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(watched ? Palette.wash : hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help("Watch \(tab.ref) in this window")
        .accessibilityLabel("Watch \(tab.tab.title)")
    }
}

private struct PanelButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? .white : Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? Palette.hover : Palette.hover.opacity(0.5)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

/// An Agent tab the owner watches in their window (`Browser.watched`): its
/// page in place of their tab's, under a line saying whose it is, with the
/// way back to their own tab. The agent carries on in it meanwhile.
struct WatchedAgentTab: View {
    let browser: Browser
    let watched: AgentTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text(owner)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text([watched.tab.title, watched.tab.url.flatMap(History.site(of:))].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                PanelButton(title: "Back to Your Tab") { browser.watched = nil }
                    .help("Leave the agent's tab and go back to yours")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Palette.panel)
            Divider()
            WatchedPage(watched: watched)
        }
        .background(Palette.ground)
    }

    /// "Claude's tab", by the session it is in.
    private var owner: String {
        let session = AgentServer.shared.session(of: watched)
        return "\(session?.title ?? "An agent")'s tab \(watched.ref)"
    }
}

/// The watched Agent tab's page in the owner's window, as `PageView` shows
/// a tab's, while it is watched; let go of, it goes back to its Agent
/// browser's window, whatever SwiftUI did last.
private struct WatchedPage: NSViewRepresentable {
    let watched: AgentTab

    func makeCoordinator() -> AgentBrowser { watched.agents }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard watched.agents.watched.contains(watched.tab.id) else { return }
        PageView(tabs: [watched.tab], selected: watched.tab, takesFocus: false).updatePages(in: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: AgentBrowser) {
        for slot in view.subviews { slot.removeFromSuperview() }
        coordinator.holdPagesNow()
    }
}
