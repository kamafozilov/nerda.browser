import Foundation

/// What goes between the `nerda-browser` shim and command line and the
/// running app: one request a connection, as one line of JSON, and one
/// answer back, over a Unix socket in the edition's data folder
/// (`AgentSocket`). Both ends are the same binary, but the app running may
/// be older or newer than the shim an agent started: `version` tells them
/// apart, and a mismatch answers "reopen Nerda" (`AgentReply.reopen`).
nonisolated enum AgentWire {
    /// Raised whenever a request or answer changes shape. A new verb is no
    /// change of shape: an app without it answers it is unknown.
    static let version = 1

    /// The longest request taken, in bytes: arguments are small, uploads
    /// go by path.
    static let maxRequest = 1 << 20
    /// The longest answer read back.
    static let maxReply = 16 << 20
    /// How long a caller has to send its request once connected.
    static let requestTimeout: Duration = .seconds(5)
    /// How long the app works on a request, unless its verb says otherwise.
    static let deadline: Duration = .seconds(25)

    /// Where the edition's app listens: Nerda, Nerda Dev and Nerda Test each
    /// have their own.
    static var socket: URL { socket(in: Edition.folder) }

    /// What the shim sends, in place of a verb, when its MCP client closes
    /// its input: the agent went away, and its session detaches. Not a verb
    /// agents see or call.
    static let detach = "detach"

    static func socket(in folder: URL) -> URL { folder.appending(path: "agents.sock") }
}

/// Which Agent session a request is for: the MCP client's name and the
/// session id its harness exports (Claude Code's session, Codex's thread),
/// so every connection one agent makes is the same session.
nonisolated struct AgentSessionName: Codable, Hashable, Sendable {
    var client: String
    var id: String
}

/// One request: a verb, its arguments, and whose.
nonisolated struct AgentRequest: Codable, Sendable {
    var v = AgentWire.version
    var verb: String
    var session: AgentSessionName?
    var args: [String: AgentJSON] = [:]
}

/// One answer: what to show the agent, and when it failed, why, as a code a
/// program can tell apart (`AgentError.Code`).
nonisolated struct AgentReply: Codable, Sendable, Equatable {
    var v = AgentWire.version
    var ok: Bool
    var text: String
    var error: String?

    static func done(_ text: String) -> AgentReply { AgentReply(ok: true, text: text) }

    static func failed(_ error: AgentError) -> AgentReply {
        AgentReply(ok: false, text: error.message, error: error.code.rawValue)
    }

    /// The app and the shim speak different versions of the wire.
    static func reopen(app: Int, shim: Int) -> AgentReply {
        failed(AgentError(.version, """
            Nerda is running a different version than this nerda-browser (wire \(app) in the app, \(shim) here). \
            Ask the user to reopen Nerda: quit it and open it again.
            """))
    }
}

nonisolated extension AgentReply {
    /// What the `nerda-browser` command line exits with for this answer:
    /// 0 done, 1 failed, 2 Nerda unreachable, 3 the owner is needed, 124
    /// timed out (130, interrupted, is the command line's own).
    var exitCode: Int32 {
        if ok { return 0 }
        switch error.flatMap(AgentError.Code.init(rawValue:)) {
        case .needsUser: return 3
        case .unreachable: return 2
        case .timedOut: return 124
        default: return 1
        }
    }

    /// Waiting on the owner, rather than failed.
    var needsUser: Bool { error == AgentError.Code.needsUser.rawValue }
}

/// A request that could not be done, with what to tell the agent.
nonisolated struct AgentError: Error, Sendable, Equatable {
    /// Each kind of failure, as it travels in `AgentReply.error`. Later
    /// verbs add theirs here.
    enum Code: String, Sendable {
        /// Wire versions differ: reopen Nerda.
        case version
        /// The caller may only ask for status (`AgentCallers`).
        case notAllowed = "not_allowed"
        /// No verb of that name in this app.
        case unknown
        /// An argument missing or of the wrong kind.
        case invalid
        /// No such Agent tab, or no longer.
        case noTab = "no_tab"
        /// Another Agent session's tab.
        case notYours = "not_yours"
        /// The page couldn't be opened.
        case failed
        /// The deadline passed first.
        case timedOut = "timed_out"
        /// Nerda isn't running, or agents are turned off (shim side only).
        case unreachable
        /// The step waits on the owner (a Handoff, a question); the agent
        /// tells them, and asks again.
        case needsUser = "needs_user"
    }

    let code: Code
    let message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

nonisolated extension AgentWire {
    /// Sends one request to the app listening at `socket` and answers what
    /// it said, or why nothing came back: the shim's and the command line's
    /// way in alike. With a `launcher` and Nerda closed, Nerda is started
    /// hidden first (`AgentLauncher`), by `start` (the shim's shares one
    /// start among the calls that find it closed together), and the request
    /// sent once it answers.
    static func send(_ request: AgentRequest, to socket: URL, launcher: AgentLauncher? = nil,
                     start: @Sendable (AgentLauncher) async -> Bool = { await $0.started() }) async -> AgentReply {
        let verb = request.verb
        let timeout = (AgentVerb.named[verb]?.deadline ?? deadline) + .seconds(5)
        guard let data = try? JSONEncoder().encode(request) else {
            return .failed(AgentError(.invalid, "The arguments to \(verb) couldn't be sent."))
        }
        do {
            return try await answer(to: data, at: socket, timeout: timeout, wire: request.v)
        } catch AgentSocket.Failure.unreachable {
            guard let launcher else { return .failed(unreachable) }
            guard await start(launcher) else {
                return .failed(launcher.app() == .open ? agentsOff : notStarted)
            }
            // Unreachable means nothing was sent: trying again does it once.
            let end = ContinuousClock.now + launcher.wait
            while true {
                do {
                    return try await answer(to: data, at: socket, timeout: timeout, wire: request.v)
                } catch AgentSocket.Failure.unreachable where ContinuousClock.now < end {
                    try? await Task.sleep(for: launcher.poll)
                } catch AgentSocket.Failure.unreachable {
                    return .failed(notStarted)
                } catch {
                    return failure(error, verb: verb)
                }
            }
        } catch {
            return failure(error, verb: verb)
        }
    }

    private static func answer(to data: Data, at socket: URL, timeout: Duration, wire: Int) async throws -> AgentReply {
        let answer = try await AgentSocket.request(data, to: socket.path, timeout: timeout)
        if let version = (try? AgentJSON(data: answer))?["v"]?.int, version != wire {
            return .reopen(app: version, shim: wire)
        }
        return try JSONDecoder().decode(AgentReply.self, from: answer)
    }

    private static func failure(_ error: any Error, verb: String) -> AgentReply {
        switch error {
        case AgentSocket.Failure.timedOut:
            .failed(AgentError(.timedOut, "Nerda didn't answer \(verb) in time."))
        case AgentSocket.Failure.unreachable:
            .failed(unreachable)
        default:
            .failed(AgentError(.failed, "Nerda's answer to \(verb) couldn't be read: \(error)"))
        }
    }

    private static let unreachable = AgentError(.unreachable, """
        Nerda isn't running, or agents are turned off in its Settings › Security & Privacy. \
        Ask the user to open Nerda.
        """)

    private static let agentsOff = AgentError(.unreachable, """
        Agents are turned off in Nerda's Settings › Security & Privacy. \
        Ask the user to turn on Agents can use Nerda there.
        """)

    private static let notStarted = AgentError(.unreachable, """
        Nerda didn't start, or agents are turned off in its Settings › Security & Privacy. \
        Ask the user to open Nerda.
        """)
}
