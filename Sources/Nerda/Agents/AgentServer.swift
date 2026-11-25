import Foundation
import os

/// Nerda's side of agents using it: listens on the edition's socket while
/// Settings › Security & Privacy › Agents can use Nerda is on, checks each
/// caller (`AgentCallers`), and does each request's verb (`AgentVerb`) for
/// its Agent session, in Agent tabs (`AgentBrowser`) of the profile.
@MainActor
final class AgentServer {
    /// The app's own, on its edition's socket.
    static let shared = AgentServer(socket: AgentWire.socket)

    /// The Settings switch, on until turned off.
    static let isOnKey = "agentsCanUseNerda"

    let socket: URL
    let sessions = AgentSessions()
    private let callers: AgentCallers
    private let defaults: UserDefaults
    private let makeBrowser: (Profile) -> AgentBrowser
    /// The owner's profiles agents may choose from, Personal first.
    private let listProfiles: () -> [Profile]
    /// Each profile's Agent browser, made on its first Agent tab.
    private var agentBrowsers: [ObjectIdentifier: AgentBrowser] = [:]
    private var listener: AgentSocket.Listener?
    private var switchWatch: NSObjectProtocol?

    init(socket: URL, callers: AgentCallers = .nerdas, defaults: UserDefaults = .standard,
         profiles: @escaping () -> [Profile] = { Profiles.shared.all },
         makeBrowser: @escaping (Profile) -> AgentBrowser = { AgentBrowser(profile: $0) }) {
        self.socket = socket
        self.callers = callers
        self.defaults = defaults
        listProfiles = profiles
        self.makeBrowser = makeBrowser
    }

    /// The owner's profiles, Personal first. Incognito is none of them.
    var profiles: [Profile] { listProfiles() }

    /// Whether agents may use Nerda (the Settings switch).
    var isOn: Bool { defaults.object(forKey: Self.isOnKey) as? Bool ?? true }

    /// Whether the socket is there for agents to reach.
    var isListening: Bool { listener != nil }

    /// Listens while the switch is on, from now on, following it as it is
    /// turned off and on.
    func start() {
        if switchWatch == nil {
            switchWatch = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        follow()
    }

    /// Stops listening for good; tabs already open stay.
    func stop() {
        if let switchWatch { NotificationCenter.default.removeObserver(switchWatch) }
        switchWatch = nil
        listener?.close()
        listener = nil
    }

    /// The Agent browsers made so far.
    var browsers: [AgentBrowser] { Array(agentBrowsers.values) }

    /// The profile's Agent browser, made the first time.
    func agents(for profile: Profile) -> AgentBrowser {
        if let made = agentBrowsers[ObjectIdentifier(profile)] { return made }
        let made = makeBrowser(profile)
        agentBrowsers[ObjectIdentifier(profile)] = made
        return made
    }

    private func follow() {
        guard isOn != isListening else { return }
        guard isOn else {
            listener?.close()
            listener = nil
            return
        }
        do {
            try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            let callers = callers
            listener = try AgentSocket.Listener(path: socket.path) { [weak self] connection in
                Self.serve(connection, callers: callers, server: self)
            }
        } catch {
            Logger.agents.error("Agents can't reach Nerda: \(String(describing: error), privacy: .public)")
        }
    }

    /// One caller, on its connection's queue: read, checked, done on the
    /// main thread, answered from here.
    private nonisolated static func serve(_ connection: AgentSocket.Connection, callers: AgentCallers, server: AgentServer?) {
        guard let access = callers.access(of: connection) else {
            // Another user's program: no answer at all.
            connection.close()
            return
        }
        guard let line = connection.readRequest() else {
            connection.close()
            return
        }
        Task {
            let reply = await server?.answer(line, access: access)
                ?? .failed(AgentError(.unreachable, "Nerda stopped listening to agents."))
            var data = (try? JSONEncoder().encode(reply)) ?? Data()
            data.append(UInt8(ascii: "\n"))
            connection.answer(data)
        }
    }

    /// The answer to one request line, from a caller with `access`.
    func answer(_ line: Data, access: AgentCallers.Access) async -> AgentReply {
        // The version first, from whatever shape the rest has: an app and a
        // shim of different versions may not read each other's.
        let version = (try? AgentJSON(data: line))?["v"]?.int
        guard version == AgentWire.version else { return .reopen(app: AgentWire.version, shim: version ?? 0) }
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
            return .failed(AgentError(.invalid, "Nerda couldn't read that request."))
        }
        guard let verb = AgentVerb.named[request.verb] else {
            return .failed(AgentError(.unknown, "Nerda has no \(request.verb). Ask the user to update Nerda."))
        }
        guard access == .full || verb.forAnyCaller else {
            return .failed(AgentError(.notAllowed, """
                This program isn't Nerda's own nerda-browser, so Nerda only tells it its status. \
                Use the nerda-browser command or MCP server that Nerda's setup installed.
                """))
        }
        let session = sessions.session(request.session ?? AgentSessionName(client: "unknown", id: "unknown"))
        let call = AgentCall(server: self, session: session, arguments: request.args, deadline: .now + verb.deadline)
        return await Self.done(verb, call)
    }

    /// The verb's answer, or "timed out" once its deadline passes first:
    /// the verb is cancelled then, and its waits end.
    private static func done(_ verb: AgentVerb, _ call: AgentCall) async -> AgentReply {
        let work = Task { @MainActor () -> AgentReply in
            do { return .done(try await verb.run(call)) }
            catch let error as AgentError { return .failed(error) }
            catch is CancellationError {
                return .failed(AgentError(.timedOut, "\(verb.name) took longer than \(verb.deadline.components.seconds) s."))
            }
            catch { return .failed(AgentError(.failed, error.localizedDescription)) }
        }
        let timer = Task {
            try await Task.sleep(for: verb.deadline)
            work.cancel()
        }
        defer { timer.cancel() }
        return await work.value
    }
}
