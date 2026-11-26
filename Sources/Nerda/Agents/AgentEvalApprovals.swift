import AppKit

/// What the owner is shown on eval's card.
struct ScriptCard {
    /// The agent asking, as the owner knows it: Claude, Codex.
    let asker: String
    /// The site of the page it would run in.
    let site: String
    /// Its Agent tab: t1.
    let tab: String
    /// The page's title, as the page gives it.
    let title: String
    /// The script, exactly as it would run.
    let script: String
}

/// Agent `eval`s, each waiting for the owner's Allow before it runs
/// (decision #43). The guard eval runs inside (`AgentEvalGuard`) is a
/// fence, not a sandbox: a `javascript:` address set through `location`
/// runs in the page's own world, and `fetch` sends straight to the site
/// with the owner's cookies, so only the owner can let a script run. They
/// hear of it as of a Handoff (a notification, the Agent row) and read the
/// script whole on a sheet over their window, which doesn't bring Nerda
/// forward. One Allow runs that script, on that tab and that site, once;
/// Don't Allow is told to the agent once.
@MainActor
final class AgentEvalApprovals {
    /// Shows the owner a script: true once they allowed it, false when
    /// they didn't, nil when they made no choice (the window closed under
    /// the sheet, or the ask went first), which runs nothing.
    typealias Approve = @MainActor (ScriptCard) async -> Bool?

    /// How long an answer waits for the agent to call again.
    static let answerLasts: Duration = .seconds(600)
    /// The time a call keeps for the script itself, once allowed.
    static let runRoom: Duration = .seconds(25)

    /// A script waiting for the owner, or answered and not yet run or told.
    final class Ask {
        enum State {
            case waiting
            case allowed(ContinuousClock.Instant)
            case refused(ContinuousClock.Instant)
        }

        let tab: AgentTab
        /// Where its page was when asked: an Allow is for there only.
        let place: String
        let script: String
        let request: OwnerRequest
        fileprivate(set) var state = State.waiting
        fileprivate var asking: Task<Void, Never>?

        fileprivate init(tab: AgentTab, place: String, script: String, request: OwnerRequest) {
            self.tab = tab
            self.place = place
            self.script = script
            self.request = request
        }

        /// The same script on the same tab.
        func isSame(_ script: String, on tab: AgentTab) -> Bool {
            self.tab.tab === tab.tab && self.script == script
        }

        var isWaiting: Bool { if case .waiting = state { true } else { false } }
    }

    private let owner: OwnerRequests
    private let approve: Approve
    private(set) var asks: [Ask] = []

    init(owner: OwnerRequests, approve: @escaping Approve) {
        self.owner = owner
        self.approve = approve
    }

    /// Where the tab's page is, as an approval is bound to it: its scheme
    /// and site.
    static func place(of tab: AgentTab) -> String {
        guard let url = tab.tab.url else { return "" }
        return (url.scheme?.lowercased() ?? "") + "://" + (History.site(of: url) ?? url.absoluteString)
    }

    /// Returns once the owner allowed this script on this tab, where its
    /// page is now; the Allow is used up. Otherwise asks them, or attaches
    /// to the ask open for it, and waits as long as the call may: fails
    /// with needs_user when they haven't answered by then, or with Don't
    /// Allow.
    func clear(_ script: String, on tab: AgentTab, for call: AgentCall) async throws {
        while true {
            let place = Self.place(of: tab)
            expire()
            if let answered = asks.first(where: { $0.isSame(script, on: tab) && $0.place == place && !$0.isWaiting }) {
                remove(answered)
                guard case .allowed = answered.state else {
                    throw AgentError(.failed, """
                        The user didn't allow this script in \(tab.ref), so Nerda didn't run it. Don't try to get it \
                        run another way: do the step with the other tools, or ask the user what to do.
                        """)
                }
                return
            }
            let ask = asks.first { $0.isSame(script, on: tab) && $0.place == place && $0.isWaiting }
                ?? begin(script, on: tab, at: place, for: call.session)
            // Asked for where the page was before: that sheet is out of date.
            for other in asks where other !== ask && other.isSame(script, on: tab) && other.isWaiting { end(other) }
            let until = ContinuousClock.now + AgentVerb.waitOnOwner(call, leaving: Self.runRoom)
            while ask.isWaiting, ask.request.answer == nil, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(100))
            }
            if ask.isWaiting {
                if ask.request.answer != nil {
                    end(ask)
                    throw AgentError(.noTab, "Tab \(tab.ref) was closed while the script waited for the user.")
                }
                throw AgentError.needsUser("""
                    Every eval waits for the user to allow its script, and they haven't yet: Nerda shows them this \
                    one in Nerda's window, and runs nothing meanwhile. Use the other tools where they do the step.
                    """, waitingIn: "in Nerda's window", again: "eval with the same script on \(tab.ref)")
            }
            // Answered: looked at again, so an Allow goes to this script, here, only.
        }
    }

    /// A script put to the owner: told (notification, Agent row) and shown
    /// its sheet; let go of if its request ends first (the tab closed, the
    /// agent stopped).
    private func begin(_ script: String, on tab: AgentTab, at place: String, for session: AgentSession) -> Ask {
        let site = tab.tab.url.flatMap(History.site(of:)) ?? "a page"
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
        let request = owner.script("""
            Run a script of \(lines) line\(lines == 1 ? "" : "s") in \(tab.ref) on \(site). Read it and allow it or not \
            on the sheet in Nerda's window.
            """, on: tab, for: session)
        let ask = Ask(tab: tab, place: place, script: script, request: request)
        asks.append(ask)
        let card = ScriptCard(asker: session.title, site: site, tab: tab.ref, title: tab.tab.title, script: script)
        ask.asking = Task { [weak self, approve] in
            let allowed = await approve(card)
            guard let self, ask.isWaiting, !Task.isCancelled else { return }
            ask.state = allowed == true ? .allowed(.now) : .refused(.now)
            owner.drop(request)
        }
        Task { [weak self] in
            while ask.isWaiting {
                if ask.request.answer != nil {
                    self?.end(ask)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return ask
    }

    /// Lets go of an ask: its sheet taken away, its request withdrawn.
    private func end(_ ask: Ask) {
        ask.asking?.cancel()
        owner.drop(ask.request)
        remove(ask)
    }

    private func remove(_ ask: Ask) {
        asks.removeAll { $0 === ask }
    }

    /// Answers nobody called for again in time.
    private func expire() {
        let now = ContinuousClock.now
        for ask in asks {
            switch ask.state {
            case .allowed(let at), .refused(let at):
                if now - at > Self.answerLasts { remove(ask) }
            case .waiting: break
            }
        }
    }

    // MARK: The sheet

    /// Shows the script whole on a sheet over the owner's window, which
    /// doesn't bring Nerda forward (with no window open, once they open
    /// one). The script is the agent's, maybe written from what a page
    /// said: shown as plain code, its invisible characters made visible.
    static func sheet(_ card: ScriptCard) async -> Bool? {
        guard let window = await AgentApprovals.ownersWindow(), !Task.isCancelled else { return nil }
        let alert = NSAlert()
        alert.messageText = "\(card.asker) wants to run a script on \(card.site)"
        let title = card.title.replacing(/\s+/, with: " ").prefix(80)
        alert.informativeText = """
            In its tab \(card.tab)\(title.isEmpty ? "" : " (“\(title)”)"). The script runs in the page as you, signed \
            in: it can read what the page shows and send to the site. Allow it only if you see what it does; \
            Allow runs it once.
            """
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        text.string = visible(card.script)
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isEditable = false
        text.isRichText = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        // Return pressed while typing in the window mustn't allow it.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let response = await withTaskCancellationHandler {
            await alert.beginSheetModal(for: window)
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .cancel) }
        }
        switch response {
        case .alertFirstButtonReturn: return Task.isCancelled ? nil : true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    /// The script with what wouldn't show, or would show as something else
    /// (text direction marks, zero-width and control characters), written
    /// as `\u{202E}`, so the owner reads what runs.
    nonisolated static func visible(_ script: String) -> String {
        var shown = String.UnicodeScalarView()
        for scalar in script.unicodeScalars {
            let category = scalar.properties.generalCategory
            let hidden = switch category {
            case .control: !["\n", "\t", "\r"].contains(scalar)
            case .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .surrogate: true
            default: false
            }
            if hidden {
                shown.append(contentsOf: String(format: "\\u{%04X}", scalar.value).unicodeScalars)
            } else {
                shown.append(scalar)
            }
        }
        return String(shown)
    }
}
