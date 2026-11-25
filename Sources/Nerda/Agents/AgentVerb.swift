import Foundation

/// One thing an agent can ask of Nerda, such as `open` or `tabs`: its name,
/// what the agent is told of it, its arguments, and what the app does. The
/// same table makes the app's answers (`AgentServer`) and the shim's MCP
/// tool list (`AgentMCP`), so a verb is added in one place: a file of its
/// own with `extension AgentVerb { static let … }`, listed in `all`.
nonisolated struct AgentVerb: Sendable {
    let name: String
    /// What the tool does, for the agent reading the tool list.
    let summary: String
    let arguments: [AgentArgument]
    /// Changes nothing (MCP's `readOnlyHint`).
    var readOnly = false
    /// May destroy something, such as a tab and what is in it (MCP's
    /// `destructiveHint`).
    var destructive = false
    /// Answers callers that only get status (`AgentCallers.Access`).
    var forAnyCaller = false
    /// How long it may take before the answer is "timed out".
    var deadline = AgentWire.deadline
    /// The group of tools it is listed in once an agent asks for it
    /// (`more_tools`); nil for the page verbs, always listed.
    var group: AgentGroup?
    /// Waits on the owner (a Handoff, a question): the shim asks again and
    /// again, with progress, while its client waits (`AgentMCP.Waits`), and
    /// passes each request how long to wait in `wait`.
    var waitsForOwner = false
    /// Does it on the main thread, for the session asking, with its
    /// arguments; the text is what the agent is shown. Throws an
    /// `AgentError` to fail with one.
    let run: @MainActor @Sendable (AgentCall) async throws -> String

    /// Every verb, in the order the tool list shows them. Each group lives in
    /// a file of its own; a ticket adding verbs adds its group's line here.
    static let all: [AgentVerb] = [
        [status],
        tabVerbs, // TabVerbs.swift
        screenshotVerbs, // ScreenshotVerbs.swift
        readingVerbs, // ReadingVerbs.swift
        actingVerbs, // ActingVerbs.swift
        keyboardVerbs, // KeyboardVerbs.swift
        dialogVerbs, // AgentDialogs.swift
        fileVerbs, // FileVerbs.swift
        lookupVerbs, // LookupVerbs.swift
        ownerVerbs, // OwnerVerbs.swift
        signInVerbs, // SignInVerbs.swift
        skillVerbs, // SiteSkills.swift
    ].flatMap(\.self)

    static let named = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// The verb as an MCP tool, for `tools/list`.
    var tool: AgentJSON {
        let properties = arguments.map { ($0.name, $0.schema) }
        var schema: [String: AgentJSON] = [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { $1 })),
        ]
        let required = arguments.filter(\.required).map { AgentJSON.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return [
            "name": .string(name),
            "description": .string(summary),
            "inputSchema": .object(schema),
            "annotations": ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive)],
        ]
    }
}

/// One argument of a verb, and its JSON schema for the tool list.
nonisolated struct AgentArgument: Sendable {
    let name: String
    let schema: AgentJSON
    let required: Bool

    static func string(_ name: String, _ description: String, required: Bool = true) -> AgentArgument {
        AgentArgument(name: name, schema: ["type": "string", "description": .string(description)], required: required)
    }

    static func integer(_ name: String, _ description: String, required: Bool = false) -> AgentArgument {
        AgentArgument(name: name, schema: ["type": "integer", "description": .string(description)], required: required)
    }

    static func boolean(_ name: String, _ description: String, required: Bool = false) -> AgentArgument {
        AgentArgument(name: name, schema: ["type": "boolean", "description": .string(description)], required: required)
    }

    /// The tab argument every verb on a tab takes.
    static let tab = string("tab", "The Agent tab, as open or tabs named it (t1)")
}

/// A verb being done: for which session, with which arguments, by when, on
/// which server. What verbs need from the app goes through here, so they
/// don't reach for it themselves.
@MainActor
struct AgentCall {
    let server: AgentServer
    let session: AgentSession
    let arguments: [String: AgentJSON]
    let deadline: ContinuousClock.Instant
    /// A picture the verb answers with, besides its text.
    let shown = Shown()

    final class Shown {
        var jpeg: Data?
    }

    /// A string argument, failing as `invalid` when missing.
    func string(_ name: String) throws -> String {
        guard let value = arguments[name]?.string, !value.isEmpty else {
            throw AgentError(.invalid, "Give \(name) as a string.")
        }
        return value
    }

    func optionalString(_ name: String) -> String? { arguments[name]?.string }

    /// An address argument: http, https, file or about, as typed in the
    /// address bar ("example.com" goes to https).
    func url(_ name: String = "url") throws -> URL {
        let text = try string(name).trimmingCharacters(in: .whitespaces)
        let typed = text.contains("://") || text.hasPrefix("about:") ? text : "https://" + text
        guard let url = URL(string: typed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "about"].contains(scheme) else {
            throw AgentError(.invalid, "\(text) is not an address Nerda can open (http, https, file or about).")
        }
        return url
    }

    /// The session's Agent tab named by the `tab` argument (`AgentSessions.tab`),
    /// awake (`AgentAwake.use`) unless only `waking: false`, as for closing it.
    func tab(_ name: String = "tab", waking: Bool = true) throws -> AgentTab {
        let tab = try server.sessions.tab(try string(name), for: session)
        if waking { server.awake.use(tab) }
        return tab
    }

    /// Time left before the deadline.
    var remaining: Duration { max(.zero, deadline - .now) }
}
