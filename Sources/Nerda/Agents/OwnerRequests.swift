import AppKit
import Observation

/// Something an Agent waits on the owner for: a Handoff on one of its tabs
/// (GLOSSARY.md), or a question with a few choices. Open until the owner
/// answers it, or its tab closes.
@Observable
final class OwnerRequest: Identifiable {
    /// What a Handoff asks the owner to do.
    enum Step: String, CaseIterable {
        case signIn = "sign_in", code, captcha, passkey, other
    }

    enum Kind: Equatable {
        case handoff(Step)
        case question(choices: [String])
        /// A page's confirm or prompt its agent left unanswered
        /// (`AgentDialog`), with the dialog's buttons as choices.
        case dialog(choices: [String])
        /// A payment its agent pressed, held for the owner's Touch ID on a
        /// sheet over their window (`AgentPayments`): nothing here answers it.
        case payment
        /// A script its agent would run with eval, waiting for the owner's
        /// Allow on a sheet over their window (`AgentEvalApprovals`):
        /// nothing here answers it either.
        case script
    }

    enum Answer: Equatable {
        /// Done, by the owner's say.
        case done
        /// An optional Handoff the owner chose not to do.
        case skipped
        /// A sign-in Handoff, ended by the tab coming back to the site.
        case signedIn
        /// The choice the owner picked, by its place.
        case picked(Int)
        /// Its tab was closed first.
        case closed
    }

    let id = UUID().uuidString
    let session: AgentSession
    /// The Agent tab it is about: a Handoff's always, a question's maybe.
    let tab: AgentTab?
    let kind: Kind
    /// The agent's words to the owner: why it hands off, or its question.
    let text: String
    /// Whether the owner may Skip it.
    let canSkip: Bool
    /// A sign-in Handoff's site (Site.of), which the tab is to be back on.
    let site: String?
    fileprivate(set) var answer: Answer?
    /// How many of its agent's requests asked for it: the first, and one
    /// more each time an agent's wait for it ended unanswered and it asked
    /// again.
    fileprivate(set) var asked = 1

    fileprivate init(session: AgentSession, tab: AgentTab?, kind: Kind, text: String, canSkip: Bool, site: String?) {
        self.session = session
        self.tab = tab
        self.kind = kind
        self.text = text
        self.canSkip = canSkip
        self.site = site
    }

    var isHandoff: Bool { if case .handoff = kind { true } else { false } }

    /// Answered only on its sheet, never by Done or a choice here.
    var isAnsweredOnSheet: Bool { kind == .payment || kind == .script }

    var choices: [String] {
        switch kind {
        case .question(let choices), .dialog(let choices): choices
        case .handoff, .payment, .script: []
        }
    }

    /// What the owner is told, after the agent's name: "needs you to sign in".
    var asking: String {
        switch kind {
        case .handoff(.signIn): "needs you to sign in"
        case .handoff(.code): "needs a code from you"
        case .handoff(.captcha): "needs you to solve a captcha"
        case .handoff(.passkey): "needs your passkey"
        case .handoff(.other): "needs you"
        case .question: "asks you"
        case .dialog: "needs you to answer a page"
        case .payment: "wants to pay"
        case .script: "wants to run a script"
        }
    }

    /// The owner's headline: "Claude needs you to sign in".
    var title: String { "\(session.title) \(asking)" }

    fileprivate var notice: AgentNotice {
        AgentNotice(id: id, title: title, subtitle: tab?.tab.url.flatMap(History.site(of:)) ?? "",
                    body: text, choices: choices)
    }
}

/// What Agents wait on the owner for, and which sessions need them: what
/// the Agent row shows as needing the owner, the line at the foot of a
/// watched Agent tab's page (`HandoffBar`), and the notifications. The
/// agent's call waits on it (`answer(to:within:)`) and, when the wait runs
/// out first, asks again later: an answer given meanwhile is kept for that.
@Observable
final class OwnerRequests {
    /// Waiting for the owner, oldest first.
    private(set) var waiting: [OwnerRequest] = []
    /// The request whose notification the owner clicked last, for the
    /// Agent row to show its tab.
    private(set) var opened: OwnerRequest?
    /// Answered while no call was waiting: the agent's next call hears it.
    @ObservationIgnored private var untold: [OwnerRequest] = []
    @ObservationIgnored private let notifier: AgentNotifier
    /// When a notification not yet answered is shown once more.
    @ObservationIgnored var repeatAfter: Duration = .seconds(180)
    /// Shows a request's tab in the owner's window, as its notification is
    /// clicked (`AgentServer.show`).
    @ObservationIgnored var show: (OwnerRequest) -> Void = { _ in }

    init(notifier: AgentNotifier) { self.notifier = notifier }

    /// Whether the session waits on the owner.
    func needs(_ session: AgentSession) -> Bool { waiting.contains { $0.session === session } }

    /// The sessions waiting on the owner, the longest waiting first.
    var sessions: [AgentSession] {
        waiting.reduce(into: []) { sessions, request in
            if !sessions.contains(where: { $0 === request.session }) { sessions.append(request.session) }
        }
    }

    /// What is waiting on the owner in `tab`, for the foot of its page.
    func handoff(on tab: Tab) -> OwnerRequest? { waiting.first { $0.tab?.tab === tab } }

    /// The Handoff open on `tab`, or answered and not yet told; else a new
    /// one, the owner told of it.
    func handoff(_ step: OwnerRequest.Step, _ reason: String, optional: Bool, site: String?,
                 on tab: AgentTab, for session: AgentSession) -> OwnerRequest {
        if let same = asked(again: { $0.isHandoff && $0.tab?.ref == tab.ref }) { return same }
        let host = tab.tab.url?.host()
        let site = step == .signIn ? (site.flatMap(Self.site) ?? host.map(Site.of)) : nil
        return begin(OwnerRequest(session: session, tab: tab, kind: .handoff(step), text: reason,
                                  canSkip: optional, site: site))
    }

    /// The same question, open or answered and not yet told; else asked.
    func ask(_ question: String, choices: [String], on tab: AgentTab?, for session: AgentSession) -> OwnerRequest {
        if let same = asked(again: {
            $0.session === session && $0.text == question && $0.kind == .question(choices: choices)
        }) { return same }
        return begin(OwnerRequest(session: session, tab: tab, kind: .question(choices: choices), text: question,
                                  canSkip: false, site: nil))
    }

    /// The request open, or answered and not yet told, that `matches`,
    /// counted as asked once more.
    private func asked(again matches: (OwnerRequest) -> Bool) -> OwnerRequest? {
        guard let same = (waiting + untold).first(where: matches) else { return nil }
        same.asked += 1
        return same
    }

    /// A page's dialog its agent left unanswered, put to the owner: always
    /// a new request, as the same words may well be asked again.
    func dialog(_ text: String, choices: [String], on tab: AgentTab, for session: AgentSession) -> OwnerRequest {
        begin(OwnerRequest(session: session, tab: tab, kind: .dialog(choices: choices), text: text, canSkip: false, site: nil))
    }

    /// A payment the agent pressed, for the owner to approve on its sheet:
    /// always a new request, as the hold it belongs to is.
    func payment(_ text: String, on tab: AgentTab, for session: AgentSession) -> OwnerRequest {
        begin(OwnerRequest(session: session, tab: tab, kind: .payment, text: text, canSkip: false, site: nil))
    }

    /// A script the agent would run with eval, for the owner to allow on its
    /// sheet: always a new request, as the ask it belongs to is.
    func script(_ text: String, on tab: AgentTab, for session: AgentSession) -> OwnerRequest {
        begin(OwnerRequest(session: session, tab: tab, kind: .script, text: text, canSkip: false, site: nil))
    }

    /// The request is no longer needed: withdrawn if still open, and told to
    /// no later call.
    func drop(_ request: OwnerRequest) {
        end(request, .closed)
        untold.removeAll { $0 === request }
    }

    /// The owner's Done. A payment or a script isn't done this way: only
    /// its sheet answers it.
    func done(_ request: OwnerRequest) {
        guard !request.isAnsweredOnSheet else { return }
        end(request, .done)
    }

    /// The owner's Skip, for an optional Handoff.
    func skip(_ request: OwnerRequest) {
        guard request.canSkip else { return }
        end(request, .skipped)
    }

    /// The owner's pick of a question's choices.
    func pick(_ request: OwnerRequest, _ choice: Int) {
        guard request.choices.indices.contains(choice) else { return }
        end(request, .picked(choice))
    }

    /// The owner clicked a request's notification, or one of its buttons:
    /// a choice is picked there; the notification itself brings Nerda
    /// forward (the owner asked) to show it.
    func clicked(_ id: String, action: String) {
        guard let request = waiting.first(where: { $0.id == id }) else { return }
        if let choice = AgentNotice.choice(of: action) {
            pick(request, choice)
        } else {
            opened = request
            NSApp.activate()
            show(request)
        }
    }

    /// The session was stopped: what it waits on the owner for goes, and no
    /// later call hears of it.
    func withdraw(_ session: AgentSession) {
        for request in waiting where request.session === session { end(request, .closed) }
        untold.removeAll { $0.session === session }
    }

    /// The request's answer once it comes, or nil if `wait` runs out first.
    /// An answer is told once: the next call asking the same starts anew.
    func answer(to request: OwnerRequest, within wait: Duration) async throws -> OwnerRequest.Answer? {
        let until = ContinuousClock.now + wait
        while request.answer == nil, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let answer = request.answer else { return nil }
        untold.removeAll { $0 === request }
        return answer
    }

    private func begin(_ request: OwnerRequest) -> OwnerRequest {
        waiting.append(request)
        notifier.post(request.notice)
        Task { [weak self, repeatAfter] in
            try? await Task.sleep(for: repeatAfter)
            guard let self, request.answer == nil else { return }
            notifier.post(request.notice)
        }
        if request.tab != nil { Task { await watch(request) } }
        return request
    }

    private func end(_ request: OwnerRequest, _ answer: OwnerRequest.Answer) {
        guard request.answer == nil else { return }
        request.answer = answer
        waiting.removeAll { $0 === request }
        untold.append(request)
        if opened === request { opened = nil }
        notifier.withdraw(request.id)
    }

    /// While it is open: ends it when its tab closes, and a sign-in Handoff
    /// once the tab is back on its site, signed in. That is, after the
    /// sign-in was seen (a sign-in form, or another site's page, such as
    /// the provider's), on a page of the site with no sign-in form, which
    /// stays so for a second: a step of the sign-in passing through ends
    /// nothing.
    private func watch(_ request: OwnerRequest) async {
        guard let agentTab = request.tab else { return }
        var sawSignIn = false
        var settled: (url: URL, since: ContinuousClock.Instant)?
        while request.answer == nil {
            guard agentTab.agents.browser.tabs.contains(where: { $0 === agentTab.tab }) else {
                end(request, .closed)
                return
            }
            if let site = request.site, let url = agentTab.tab.url, !agentTab.tab.isLoading {
                let onSite = url.host().map(Site.of) == site
                let signingIn = onSite ? await Self.asksToSignIn(agentTab.tab) : true
                if signingIn {
                    sawSignIn = true
                    settled = nil
                } else if sawSignIn {
                    if let settled, settled.url == url, ContinuousClock.now - settled.since >= .seconds(1) {
                        end(request, .signedIn)
                        return
                    }
                    if settled?.url != url { settled = (url, .now) }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// The site of an address or host an agent named.
    private static func site(_ named: String) -> String? {
        let host = URL(string: named.contains("://") ? named : "https://" + named)?.host()
        return host.map(Site.of)
    }

    /// Whether the page shows a sign-in form: a password, a user name, or a
    /// one-time code to fill in.
    private static func asksToSignIn(_ tab: Tab) async -> Bool {
        guard let page = tab.page else { return false }
        let found = try? await page.callAsyncJavaScript("""
            const shown = e => { const box = e.getBoundingClientRect(), style = getComputedStyle(e);
                return box.width > 0 && box.height > 0 && style.visibility !== 'hidden' && style.display !== 'none'; };
            return [...document.querySelectorAll('input')].some(input => shown(input) && (input.type === 'password'
                || /username|one-time-code|webauthn/.test(input.autocomplete)
                || /otp|2fa|totp|one.?time|verification.?code/i.test(input.name + ' ' + input.id)));
            """, contentWorld: AgentPage.world)
        return found as? Bool ?? false
    }
}
