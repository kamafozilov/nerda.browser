import Foundation
import WebKit

/// A confirm or prompt an Agent tab's page raised and waits on. Its agent
/// is told (`AgentNotices`) and answers it with the `dialog` verb; one left
/// unanswered goes to the owner (`AgentServer.dialogsReachOwnerAfter`).
/// Until then the page is held: it runs no script. An alert needs no
/// answer and a leave-page question is answered "leave" (`Browser`), so
/// neither is one of these.
@MainActor
final class AgentDialog {
    enum Kind: Equatable {
        case confirm
        case prompt(defaultText: String)

        var name: String {
            switch self {
            case .confirm: "confirm dialog"
            case .prompt: "prompt"
            }
        }
    }

    enum Answer: Equatable {
        /// OK, with a prompt's text.
        case ok(String?)
        case cancel
    }

    let kind: Kind
    let message: String
    /// Who asks, as the owner's sheets put it: "example.com says".
    let asker: String
    private(set) var answer: Answer?
    private var hold: AgentNotices.Hold?
    private var continuation: CheckedContinuation<Answer, Never>?

    private init(kind: Kind, message: String, asker: String) {
        self.kind = kind
        self.message = message
        self.asker = asker
    }

    /// What an Agent tab's agent is told when its page asked to stay, or
    /// had something typed in it, and was left all the same.
    static let leftAnyway = "left a page that asked to stay (a leave-page question, answered leave)"

    /// `the confirm dialog "Delete the draft?"`
    var named: String { "the \(kind.name) \(Self.quoted(message))" }

    /// The page's words as an answer quotes them: on one line, cut short.
    static func quoted(_ text: String) -> String {
        String(reflecting: String(text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces).prefix(300)))
    }

    /// Answers it: the page runs again, given `answer`. Only the first
    /// answer counts.
    func answer(_ answer: Answer) {
        guard self.answer == nil else { return }
        self.answer = answer
        hold?.end()
        continuation?.resume(returning: answer)
        continuation = nil
    }

    private static let open = NSMapTable<Tab, AgentDialog>.weakToStrongObjects()

    /// The dialog the tab's page waits on now, if any.
    static func on(_ tab: Tab) -> AgentDialog? { open.object(forKey: tab)?.answer == nil ? open.object(forKey: tab) : nil }

    /// Raises a dialog in `tab` of an Agent browser and waits for its answer:
    /// the agent's, or the owner's once it has gone to them. Cancelled
    /// should the tab close or its page go first.
    static func raise(_ kind: Kind, _ message: String, by asker: String, on tab: Tab, page: WKWebView,
                      in browser: Browser) async -> Answer {
        let dialog = AgentDialog(kind: kind, message: message, asker: asker)
        open.setObject(dialog, forKey: tab)
        dialog.hold = AgentNotices.hold(tab, "raised a \(kind.name): \(quoted(message)) (answer it with dialog)")
        let watch = Task { [weak tab, weak browser] in
            while dialog.answer == nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard let tab, let browser, tab.page === page, browser.tabs.contains(where: { $0 === tab }) else {
                    dialog.answer(.cancel)
                    return
                }
            }
        }
        defer {
            watch.cancel()
            if open.object(forKey: tab) === dialog { open.removeObject(forKey: tab) }
        }
        browser.agentServer?.raised(dialog, on: tab)
        return await withCheckedContinuation { continuation in
            if let answer = dialog.answer { continuation.resume(returning: answer) } else { dialog.continuation = continuation }
        }
    }
}

extension AgentServer {
    /// A dialog raised in one of this server's Agent tabs: should nothing
    /// answer it within `dialogsReachOwnerAfter`, it goes to the owner as
    /// a question with its buttons (the Agent row, a notification, the
    /// line at the foot of its page), and the first answer, theirs or the
    /// agent's, counts.
    func raised(_ dialog: AgentDialog, on tab: Tab) {
        let after = dialogsReachOwnerAfter
        Task { [weak self] in
            try? await Task.sleep(for: after)
            guard let self, dialog.answer == nil else { return }
            await toOwner(dialog, on: tab)
        }
    }

    private func toOwner(_ dialog: AgentDialog, on tab: Tab) async {
        guard let session = sessions.all.first(where: { $0.tabs.contains { $0.tab === tab } }),
              let agentTab = session.tabs.first(where: { $0.tab === tab }) else { return }
        var text = "\(dialog.asker): \(AgentDialog.quoted(dialog.message))"
        if case .prompt(let defaultText) = dialog.kind {
            text += defaultText.isEmpty ? " (OK answers with nothing typed)" : " (OK answers \(AgentDialog.quoted(defaultText)))"
        }
        AgentNotices.post("\(dialog.named) went unanswered too long, so it went to the user", on: tab)
        let request = owner.dialog(text, choices: ["OK", "Cancel"], on: agentTab, for: session)
        while dialog.answer == nil, request.answer == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if dialog.answer == nil, let answer = request.answer {
            if case .picked(0) = answer {
                if case .prompt(let defaultText) = dialog.kind { dialog.answer(.ok(defaultText)) } else { dialog.answer(.ok(nil)) }
                AgentNotices.post("the user answered \(dialog.named): OK", on: tab)
            } else {
                dialog.answer(.cancel)
                if case .picked = answer { AgentNotices.post("the user answered \(dialog.named): Cancel", on: tab) }
            }
        }
        owner.drop(request)
    }

    /// A popup or new window a page of one of this server's Agent tabs
    /// opened: an Agent tab of the opener's session from the start.
    func opened(_ tab: Tab, by opener: Tab?) {
        guard let opener,
              let session = sessions.all.first(where: { !$0.isStopped && $0.tabs.contains { $0.tab === opener } }),
              let agents = session.tabs.first(where: { $0.tab === opener })?.agents else { return }
        sessions.add(tab, in: agents, to: session)
    }
}

/// Answering a page's dialog.
nonisolated extension AgentVerb {
    static let dialogVerbs: [AgentVerb] = [dialog]

    static let dialog = AgentVerb(
        name: "dialog",
        summary: """
            Answer the confirm or prompt dialog an Agent tab's page waits on: accept true is OK, false is Cancel; \
            text is what a prompt is answered with (its default if left out). Answers of other verbs say when a \
            dialog came up; until it is answered the page can't be read or acted on. Alerts are accepted by \
            themselves and leave-page questions answered leave. A dialog left unanswered goes to the user after \
            2 minutes. Answers with what the answer changed, as click does.
            """,
        arguments: [
            .tab,
            .boolean("accept", "OK (true) or Cancel (false)", required: true),
            .string("text", "A prompt's answer", required: false),
        ]
    ) { call in
        let tab = try call.tab()
        guard let accept = call.arguments["accept"]?.bool else {
            throw AgentError(.invalid, "Give accept: true for OK, false for Cancel.")
        }
        guard let dialog = AgentDialog.on(tab.tab) else {
            throw AgentError(.failed, """
                Tab \(tab.ref)'s page waits on no dialog. Alerts are accepted by themselves, and the answers of \
                other verbs say when a confirm or prompt comes up.
                """)
        }
        let text = call.optionalString("text")
        return try await AgentPage.act(tab, for: call, answeringDialog: true) {
            guard accept else {
                dialog.answer(.cancel)
                return "answered \(dialog.named): Cancel"
            }
            guard case .prompt(let defaultText) = dialog.kind else {
                dialog.answer(.ok(nil))
                return "answered \(dialog.named): OK"
            }
            let typed = text ?? defaultText
            dialog.answer(.ok(typed))
            return "answered \(dialog.named) with \(AgentDialog.quoted(typed))"
        }
    }
}
