import Foundation

/// Asking the owner: a Handoff for a step only a person can do, and a
/// question with a few choices. Each waits on the owner (`OwnerRequests`);
/// the shim keeps the agent's call waiting, with progress, or answers
/// needs_user for the agent to tell the owner and call again.
nonisolated extension AgentVerb {
    static let ownerVerbs: [AgentVerb] = [handoff, ask]

    /// How long one request waits on the owner when the caller says nothing
    /// (`wait`, in seconds, which the shim sets).
    static let ownerWait: Duration = .seconds(15)

    static let handoff = AgentVerb(
        name: "handoff",
        summary: """
            Hand an Agent tab to the user for a step only a person can do: signing in, a one-time code, \
            a captcha, a passkey. They get a notification; wait for them to finish. A sign_in ends by \
            itself once the tab is back on the site, signed in; others when the user presses Done (or Skip, \
            when optional). Answers needs_user if they haven't yet: tell the user, then call handoff on the \
            same tab again to keep waiting.
            """,
        arguments: [
            .tab,
            .string("reason", "What the user should do, in a short sentence they will read, such as \"Sign in to GitHub\""),
            AgentArgument(name: "step", schema: [
                "type": "string",
                "enum": .array(OwnerRequest.Step.allCases.map { .string($0.rawValue) }),
                "description": "The kind of step: sign_in, code, captcha, passkey or other (the default)",
            ], required: false),
            .boolean("optional", "Whether the user may skip it, for a step you can go on without"),
            .string("site", "For sign_in: the site the tab should be back on once signed in (default: the tab's site now)",
                    required: false),
        ],
        waitsForOwner: true
    ) { call in
        let tab = try call.tab()
        let reason = try call.string("reason")
        let named = call.optionalString("step") ?? OwnerRequest.Step.other.rawValue
        guard let step = OwnerRequest.Step(rawValue: named) else {
            throw AgentError(.invalid, "step is one of sign_in, code, captcha, passkey or other.")
        }
        let owner = call.server.owner
        let request = owner.handoff(step, reason, optional: call.arguments["optional"]?.bool ?? false,
                                    site: call.optionalString("site"), on: tab, for: call.session)
        guard let answer = try await owner.answer(to: request, within: waitOnOwner(call)) else {
            throw AgentError.needsUser("""
                Nerda has asked the user to do this in \(tab.ref) ("\(request.text)"), and they haven't finished yet.
                """, again: "handoff on \(tab.ref)")
        }
        let page = AgentPage.header(tab).joined(separator: "\n")
        switch answer {
        case .signedIn:
            return "The user signed in; \(tab.ref) is back on \(request.site ?? "the site").\n" + page
        case .skipped:
            return "The user skipped this (\(request.text)). Go on without it.\n" + page
        case .closed:
            throw AgentError(.noTab, "Tab \(tab.ref) was closed while waiting for the user.")
        case .done, .picked:
            return "The user is done (\(request.text)). Carry on in \(tab.ref); the page may have changed.\n" + page
        }
    }

    static let ask = AgentVerb(
        name: "ask",
        summary: """
            Ask the user a question with two to four choices, and get their pick. They get a notification \
            with the choices. Answers needs_user if they haven't picked yet: tell the user, then call ask \
            again with the same question and choices to keep waiting.
            """,
        arguments: [
            .string("question", "The question, short and plain"),
            AgentArgument(name: "choices", schema: [
                "type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 4,
                "description": "Two to four short answers the user can pick from",
            ], required: true),
            .string("tab", "The Agent tab the question is about, if any (t1)", required: false),
        ],
        waitsForOwner: true
    ) { call in
        let question = try call.string("question")
        let choices = call.arguments["choices"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        guard (2...4).contains(choices.count) else {
            throw AgentError(.invalid, "Give choices as two to four strings: no more than four fit.")
        }
        let tab = try call.optionalString("tab").map { _ in try call.tab() }
        let owner = call.server.owner
        let request = owner.ask(question, choices: choices, on: tab, for: call.session)
        guard let answer = try await owner.answer(to: request, within: waitOnOwner(call)) else {
            throw AgentError.needsUser("Nerda has asked the user \"\(question)\", and they haven't picked yet.",
                                       again: "ask with the same question and choices")
        }
        switch answer {
        case .picked(let choice): return "The user picked: \(choices[choice])"
        case .closed: throw AgentError(.noTab, "Tab \(tab?.ref ?? "") was closed while waiting for the user.")
        default: return "The user didn't pick any."
        }
    }

    /// How long this request waits on the owner: as the caller asked,
    /// inside the deadline.
    @MainActor
    static func waitOnOwner(_ call: AgentCall, leaving margin: Duration = .seconds(1)) -> Duration {
        let asked = call.arguments["wait"]?.number.map { Duration.seconds(max(0, $0)) } ?? ownerWait
        return min(asked, call.remaining - margin)
    }
}
