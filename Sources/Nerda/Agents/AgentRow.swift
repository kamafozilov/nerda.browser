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
    /// The sessions the row is about, the first in front: those needing
    /// the owner, else those at work, else those done with tabs open.
    var shown: [AgentSession] = []
    /// The row's state; nil when it doesn't show.
    var state: State?
    /// What the row says: "Claude", "3 agents", "Claude needs you".
    var title = ""
}

extension AgentServer {
    /// How long after its last request a session with Agent tabs open still
    /// counts as at work: its agent is working out the next step.
    static let atWorkFor: Duration = .seconds(60)
    /// The same with none open: an agent that closed them is done, and
    /// one that never opened any (fetch, history) shows only as it asks.
    static let atWorkWithoutTabsFor: Duration = .seconds(15)
    /// How long the row still says what a request did once it is answered,
    /// before it says the agent is thinking: long enough to read.
    static let stepShownFor: Duration = .seconds(3)

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
            let busy = session.working > 0 || now - session.lastUsed < atWork(for: session)
            if busy, !session.isStopped, !session.isDetached {
                activity.atWork.append(session)
            } else {
                activity.earlier.append(session)
            }
        }
        if let first = activity.needsYou.first {
            activity.state = .needsYou
            activity.shown = activity.needsYou
            activity.title = activity.needsYou.count == 1 ? "\(first.title) needs you"
                : "\(activity.needsYou.count) agents need you"
        } else if !activity.atWork.isEmpty {
            activity.state = .atWork
            activity.shown = activity.atWork
            activity.title = Self.names(activity.atWork)
        } else {
            let left = activity.earlier.filter { !openTabs(of: $0).isEmpty }
            if !left.isEmpty {
                activity.state = .idle
                activity.shown = left
                activity.title = Self.names(left)
            }
        }
        return activity
    }

    /// How long after its last request the session still counts as at
    /// work: none once it closed its last tab.
    private func atWork(for session: AgentSession) -> Duration {
        if !openTabs(of: session).isEmpty { return Self.atWorkFor }
        return session.lastStep?.verb == AgentVerb.close.name ? .zero : Self.atWorkWithoutTabsFor
    }

    /// What the session at work is doing, as the row says it: its request
    /// now, the last one for a moment after, then that it is thinking.
    func doing(_ session: AgentSession) -> String {
        if let step = session.step { return step.words }
        if let last = session.lastStep, sessions.now() - session.lastUsed < Self.stepShownFor { return last.words }
        return AgentStep.thinking
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
/// at work and what they are doing, or that one needs the owner, opening a
/// panel of them all. Shown only while there is something to show, and
/// never in incognito windows, which agents don't see.
struct AgentRow: View {
    let browser: Browser
    var server: AgentServer = .shared
    /// The small one of the tabs across the top: an icon and a few words.
    var compact = false

    var body: some View {
        // Sessions and requests are observed; time going by, which ends
        // being at work and turns a step into thinking, is looked at each
        // second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
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
        let state = browser.isPrivate ? nil : activity.state
        VStack(spacing: 0) {
            if let state {
                Button { shown.toggle() } label: {
                    AgentRowLabel(title: activity.title, detail: detail(activity, state), state: state,
                                  agents: activity.shown.map(\.kind), compact: compact, lit: hovering || shown,
                                  watching: browser.watchedTab != nil)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering = $0 }
                .help("Agents")
                .accessibilityLabel("\(activity.title), \(detail(activity, state))")
                .popover(isPresented: $shown, arrowEdge: compact ? .bottom : .top) {
                    AgentPanel(browser: browser, server: server) { shown = false }
                        .popoverGlass()
                }
                .transition(Motion.moving(.move(edge: .bottom).combined(with: .opacity)))
            }
        }
        // In as an agent starts, out as the last one is done.
        .animation(Motion.fading(.snappy(duration: 0.3)), value: state)
    }

    private func detail(_ activity: AgentActivity, _ state: AgentActivity.State) -> String {
        switch state {
        case .needsYou:
            // The agent's own words, when it asks one thing.
            let requests = server.owner.waiting.filter { !$0.session.isStopped }
            return requests.count == 1 ? requests[0].text : "\(requests.count) things wait for you"
        case .atWork:
            // What the one heard from last does, by name when there are more.
            guard let latest = activity.atWork.first else { return AgentStep.thinking }
            let doing = server.doing(latest)
            return activity.atWork.count == 1 ? doing : "\(latest.title): \(doing)"
        case .idle:
            let tabs = activity.earlier.reduce(0) { $0 + server.openTabs(of: $1).count }
            return tabs == 1 ? "Done · 1 tab open" : "Done · \(tabs) tabs open"
        }
    }
}

/// What the Agent row shows, at one moment: its mark, its name and what it
/// is doing, the words shimmering while agents work. Apart from the button
/// so a picture of it can be drawn at any moment of its motion (`time`).
struct AgentRowLabel: View {
    let title: String
    let detail: String
    let state: AgentActivity.State
    /// Whose it is, the one in front first.
    var agents: [AgentSession.Kind] = []
    var compact = false
    /// Under the pointer, or its panel open.
    var lit = false
    /// An Agent tab is on screen in this window.
    var watching = false
    /// The moment drawn, in seconds; nil for the clock, moving while agents
    /// work.
    var time: Double?

    var body: some View {
        if let time {
            label(time)
        } else {
            Moving(moves: state == .atWork) { label($0) }
        }
    }

    /// Its content drawn at the clock's moment, in seconds: each frame while
    /// it `moves` (and Reduce Motion is off), else once.
    struct Moving<Content: View>: View {
        let moves: Bool
        @ViewBuilder let content: (Double) -> Content

        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !moves || Motion.reduced)) { context in
                content(context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    @ViewBuilder
    private func label(_ time: Double) -> some View {
        if compact { small(time) } else { row(time) }
    }

    private func row(_ time: Double) -> some View {
        HStack(spacing: 10) {
            AgentMark(state: state, agents: agents, time: time)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                ZStack(alignment: .leading) {
                    ShimmerText(text: detail, shimmers: state == .atWork, time: time)
                        .font(.system(size: 11))
                        .id(detail)
                        .transition(Motion.moving(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity))))
                }
                .clipped()
                .animation(Motion.fading(.snappy(duration: 0.25)), value: detail)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(lit ? Palette.ink : Palette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(watching ? Palette.wash : lit ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func small(_ time: Double) -> some View {
        HStack(spacing: 6) {
            AgentMark(state: state, agents: agents, size: 18, time: time)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(lit ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
    }
}

/// The Agent row's mark: the agent's own, Claude's or Codex's, with an arc
/// running round it while it works; a hand on it while it needs the owner;
/// greyed with a tick once it is done, its tabs still open. Of two agents
/// or more, the first two, the one in front first.
struct AgentMark: View {
    let state: AgentActivity.State
    var agents: [AgentSession.Kind] = []
    var size: CGFloat = 26
    /// The moment drawn, in seconds (`AgentRowLabel.time`).
    var time: Double = 0

    /// Seconds for the arc to go round once.
    private static let turn = 1.1
    /// Seconds for the agent's mark to grow and shrink back.
    private static let breath = 2.2

    var body: some View {
        let kinds = Self.firstTwo(agents)
        let working = state == .atWork
        let gap = size * 0.13
        let arc = max(1.5, size * 0.07)
        // The ring of space round the one in front, cut from what is behind.
        let reach = size / 2 + (working ? gap + arc / 2 : 0) + max(1.5, size * 0.07)
        let apart = size * 0.62
        let badge = size * 0.5
        let badgeCentre = CGPoint(x: size * 0.92, y: size * 0.9)
        let holeForBadge = badge / 2 + max(1.5, size * 0.06)
        ZStack(alignment: .leading) {
            if kinds.count > 1 {
                AgentAvatar(kind: kinds[1], size: size)
                    .grayscale(state == .idle ? 1 : 0)
                    .opacity(state == .idle ? 0.55 : 1)
                    .mask(Holes(holes: [(CGPoint(x: size / 2 - apart, y: size / 2), reach),
                                        (CGPoint(x: badgeCentre.x - apart, y: badgeCentre.y), hasBadge ? holeForBadge : 0)]))
                    .offset(x: apart)
            }
            AgentAvatar(kind: kinds[0], size: size, breath: breath)
                .grayscale(state == .idle ? 1 : 0)
                .opacity(state == .idle ? 0.55 : 1)
                .mask(Holes(holes: [(badgeCentre, hasBadge ? holeForBadge : 0)]))
                .overlay {
                    if working { ring(kinds[0], gap: gap, width: arc) }
                }
                .overlay(alignment: .topLeading) {
                    if hasBadge {
                        Image(systemName: state == .needsYou ? "hand.raised.fill" : "checkmark")
                            .font(.system(size: badge * 0.55, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: badge, height: badge)
                            .background(state == .needsYou ? AnyShapeStyle(Color.orange.gradient)
                                        : AnyShapeStyle(Color.green.gradient), in: Circle())
                            .offset(x: badgeCentre.x - badge / 2, y: badgeCentre.y - badge / 2)
                    }
                }
        }
        .frame(width: size + (kinds.count > 1 ? apart : 0), height: size, alignment: .leading)
    }

    private var hasBadge: Bool { state != .atWork }

    /// 0 to 1 and back, as the mark breathes while it works.
    private var breath: Double {
        guard state == .atWork, !Motion.reduced else { return 0 }
        return (1 - cos(time / Self.breath * 2 * .pi)) / 2
    }

    /// The arc going round the agent in front, in its colour.
    private func ring(_ kind: AgentSession.Kind, gap: CGFloat, width: CGFloat) -> some View {
        let colour = AgentAvatar.ink(of: kind)
        let turned = Motion.reduced ? -90 : time.truncatingRemainder(dividingBy: Self.turn) / Self.turn * 360
        return Circle()
            .inset(by: -gap)
            .trim(from: 0, to: 0.72)
            .stroke(AngularGradient(colors: [colour.opacity(0), colour], center: .center,
                                    startAngle: .zero, endAngle: .degrees(0.72 * 360)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            .rotationEffect(.degrees(turned))
    }

    /// The first two kinds, each once, in order; one unknown if none.
    static func firstTwo(_ kinds: [AgentSession.Kind]) -> [AgentSession.Kind] {
        var seen: [AgentSession.Kind] = []
        for kind in kinds where !seen.contains(kind) && seen.count < 2 { seen.append(kind) }
        return seen.isEmpty ? [.other] : seen
    }
}

/// An agent's own mark on a disc: Claude's in white on its clay, Codex's in
/// white on black, sparkles in the accent for any other.
struct AgentAvatar: View {
    let kind: AgentSession.Kind
    var size: CGFloat = 26
    /// 0 to 1, as it breathes while at work.
    var breath: Double = 0

    /// Claude's clay, from its mark.
    static let clay = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    /// The colour of the agent: its arc's.
    static func ink(of kind: AgentSession.Kind) -> Color {
        switch kind {
        case .claude: clay
        case .codex: .white
        case .other: .accentColor
        }
    }

    var body: some View {
        mark
            .scaleEffect(0.92 + 0.12 * breath)
            .frame(width: size, height: size)
            .background(disc, in: Circle())
            .overlay {
                if kind == .codex { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
            }
    }

    @ViewBuilder
    private var mark: some View {
        switch kind {
        case .claude, .codex:
            Image(nsImage: kind == .claude ? AgentLogo.claude : AgentLogo.openAI)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: size * (kind == .claude ? 0.6 : 0.56), height: size * (kind == .claude ? 0.6 : 0.56))
        case .other:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var disc: AnyShapeStyle {
        switch kind {
        case .claude: AnyShapeStyle(Self.clay.gradient)
        case .codex: AnyShapeStyle(LinearGradient(colors: [Color(white: 0.2), .black], startPoint: .top, endPoint: .bottom))
        case .other: AnyShapeStyle(Color.accentColor.gradient)
        }
    }
}

/// A mask with round holes in it, each where and as wide as given; a hole
/// of no width is none.
private struct Holes: View {
    let holes: [(centre: CGPoint, radius: CGFloat)]

    var body: some View {
        Rectangle()
            .overlay(alignment: .topLeading) {
                ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                    if hole.radius > 0 {
                        Circle()
                            .frame(width: hole.radius * 2, height: hole.radius * 2)
                            .offset(x: hole.centre.x - hole.radius, y: hole.centre.y - hole.radius)
                            .blendMode(.destinationOut)
                    }
                }
            }
            .compositingGroup()
    }
}

/// Words with a band of light running across them, the way an assistant
/// shows it is thinking; plain while `shimmers` is off, or with Reduce
/// Motion.
struct ShimmerText: View {
    let text: String
    let shimmers: Bool
    /// The moment drawn, in seconds (`AgentRowLabel.time`).
    var time: Double = 0

    /// Seconds from one band to the next: it crosses in `sweep`, then rests.
    private static let period = 2.4
    private static let sweep = 1.6

    var body: some View {
        if shimmers, !Motion.reduced {
            // From well before the words to well after, so it comes in and
            // goes out whole.
            let progress = min(1, time.truncatingRemainder(dividingBy: Self.period) / Self.sweep)
            let centre = -0.4 + 1.8 * progress
            Text(text).foregroundStyle(
                LinearGradient(stops: [.init(color: Palette.muted, location: 0),
                                       .init(color: Palette.ink, location: 0.5),
                                       .init(color: Palette.muted, location: 1)],
                               startPoint: UnitPoint(x: centre - 0.35, y: 0.5),
                               endPoint: UnitPoint(x: centre + 0.35, y: 0.5))
            )
        } else {
            Text(text).foregroundStyle(Palette.muted)
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
        // As the row: what each does turns into thinking as time goes by.
        TimelineView(.periodic(from: .now, by: 1)) { _ in list }
    }

    private var list: some View {
        let activity = server.activity()
        return ScrollView {
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
            HStack(spacing: 10) {
                AgentRowLabel.Moving(moves: state == .atWork) { time in
                    HStack(spacing: 10) {
                        if state == .idle {
                            // Earlier: its mark, greyed, with no tick.
                            AgentAvatar(kind: session.kind, size: 24)
                                .grayscale(1)
                                .opacity(0.55)
                        } else {
                            AgentMark(state: state, agents: [session.kind], size: 24, time: time)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            ShimmerText(text: status(tabs: tabs.count), shimmers: state == .atWork, time: time)
                                .font(.system(size: 11))
                        }
                        .lineLimit(1)
                    }
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
                AgentTabRow(tab: tab, watched: browser.watchedTab === tab.tab, taken: tab.isTaken) {
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
        case .atWork: server.doing(session)
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
    /// The owner took it over.
    let taken: Bool
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
                if taken {
                    Text("Yours")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
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
/// way back to their own tab. The agent carries on in it meanwhile, until
/// the owner takes it over (AgentTakeOver.swift), which the line says, with
/// the way to hand it back; or they keep it as a tab of their own.
struct WatchedAgentTab: View {
    let browser: Browser
    let watched: AgentTab

    private var server: AgentServer { watched.agents.browser.agentServer ?? .shared }

    var body: some View {
        let taken = watched.isTaken
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: taken ? "hand.raised.fill" : "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(taken ? Color.orange : Color.accentColor)
                Text(taken ? "You have \(owner)" : owner)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text([watched.tab.title, watched.tab.url.flatMap(History.site(of:))].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if taken {
                    PanelButton(title: "Hand Back  ⌘↩", prominent: true) { server.handBack(watched) }
                        .help("Give the tab back to the agent, to carry on in it")
                } else {
                    PanelButton(title: "Take Over  ⌘.") { server.takeOver(watched) }
                        .help("Take the tab: the agent waits until you hand it back")
                }
                if server.canKeep(watched, in: browser) {
                    PanelButton(title: "Keep as My Tab") { server.keep(watched, in: browser) }
                        .help("Make it one of your tabs; the agent no longer has it")
                }
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
