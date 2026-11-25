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
    let sessions: AgentSessions
    /// Which other programs the owner let in.
    let approvals: AgentApprovals
    /// What agents wait on the owner for: Handoffs and questions.
    let owner: OwnerRequests
    /// Which Agent tabs run at full speed, and how many stay awake.
    let awake = AgentAwake()
    private let callers: AgentCallers
    private let defaults: UserDefaults
    private let makeBrowser: (Profile) -> AgentBrowser
    /// The owner's profiles agents may choose from, Personal first.
    private let listProfiles: () -> [Profile]
    /// Each profile's Agent browser, made on its first Agent tab.
    private var agentBrowsers: [ObjectIdentifier: AgentBrowser] = [:]
    private var listener: AgentSocket.Listener?
    private var switchWatch: NSObjectProtocol?
    /// Cleanup's sweep, once a minute of awake time.
    private var sweeping: Task<Void, Never>?

    /// `now` is awake time (`AgentSessions.now`); tests move their own.
    init(socket: URL, callers: AgentCallers = .nerdas, defaults: UserDefaults = .standard,
         profiles: @escaping () -> [Profile] = { Profiles.shared.all },
         notifier: AgentNotifier = MacAgentNotifier(),
         now: @escaping () -> SuspendingClock.Instant = { .now },
         ask: @escaping AgentApprovals.Ask = AgentApprovals.sheet,
         makeBrowser: @escaping (Profile) -> AgentBrowser = { AgentBrowser(profile: $0) }) {
        self.socket = socket
        owner = OwnerRequests(notifier: notifier)
        sessions = AgentSessions(now: now)
        sessions.waitsOnOwner = { [owner] tab in owner.handoff(on: tab.tab) != nil }
        self.callers = callers
        self.defaults = defaults
        approvals = AgentApprovals(defaults: defaults, ask: ask)
        listProfiles = profiles
        self.makeBrowser = makeBrowser
    }

    /// The owner's profiles, Personal first. Incognito is none of them.
    var profiles: [Profile] { listProfiles() }

    /// Whether agents may use Nerda (the Settings switch).
    var isOn: Bool { defaults.object(forKey: Self.isOnKey) as? Bool ?? true }

    /// Whether the socket is there for agents to reach.
    var isListening: Bool { listener != nil }

    /// Requests being worked on now.
    private(set) var working = 0
    /// When a request last came or was answered; nil before the first.
    private(set) var lastUsed: ContinuousClock.Instant?

    /// Listens while the switch is on, from now on, following it as it is
    /// turned off and on; and cleans up finished sessions' tabs, switch or
    /// not.
    func start() {
        if sweeping == nil {
            sweeping = Task { [weak self] in
                // The suspending clock stands still while the Mac sleeps.
                while (try? await Task.sleep(for: AgentSessions.sweepEvery, tolerance: .seconds(10), clock: .suspending)) != nil {
                    self?.cleanUp()
                }
            }
        }
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
        sweeping?.cancel()
        sweeping = nil
        if let switchWatch { NotificationCenter.default.removeObserver(switchWatch) }
        switchWatch = nil
        listener?.close()
        listener = nil
    }

    /// Closes finished sessions' Agent tabs (`AgentSessions.cleanUp`), as
    /// the sweep does each minute.
    func cleanUp() { sessions.cleanUp() }

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
        working += 1
        lastUsed = .now
        defer {
            working -= 1
            lastUsed = .now
        }
        // The version first, from whatever shape the rest has: an app and a
        // shim of different versions may not read each other's.
        let version = (try? AgentJSON(data: line))?["v"]?.int
        guard version == AgentWire.version else { return .reopen(app: AgentWire.version, shim: version ?? 0) }
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
            return .failed(AgentError(.invalid, "Nerda couldn't read that request."))
        }
        let name = request.session ?? AgentSessionName(client: "unknown", id: "unknown")
        if request.verb == AgentWire.detach {
            if refusal(for: access, asking: false) == nil { sessions.detach(name) }
            return .done("")
        }
        guard let verb = AgentVerb.named[request.verb] else {
            return .failed(AgentError(.unknown, "Nerda has no \(request.verb). Ask the user to update Nerda."))
        }
        if !verb.forAnyCaller, let refusal = refusal(for: access) { return .failed(refusal) }
        let session = sessions.began(name)
        defer { sessions.finished(session) }
        let call = AgentCall(server: self, session: session, arguments: request.args, deadline: .now + verb.deadline)
        awake.working(session, tabs: sessions.tabs(of: session))
        defer {
            awake.working(session, tabs: sessions.tabs(of: session))
            awake.keepToCap(browsers.flatMap(\.tabs))
        }
        return await Self.done(verb, call)
    }

    /// Why a caller with `access` gets status only, nil when it gets more.
    /// Another signed program is asked about here, the first time, unless
    /// not `asking`.
    private func refusal(for access: AgentCallers.Access, asking: Bool = true) -> AgentError? {
        switch access {
        case .full:
            return nil
        case .statusOnly:
            return AgentError(.notAllowed, """
                This program isn't Nerda's own nerda-browser, so Nerda only tells it its status. \
                Use the nerda-browser command or MCP server that Nerda's setup installed.
                """)
        case .unknown(let program):
            switch approvals.decision(for: program) {
            case true?:
                return nil
            case false?:
                return AgentError(.notAllowed, """
                    The user didn't allow \(program.name) to use Nerda, so Nerda only tells it its status. \
                    Use the nerda-browser command or MCP server that Nerda's setup installed, or ask the user \
                    to remove \(program.name) in Nerda's Settings › Security & Privacy › Agents to be asked again.
                    """)
            case nil:
                if asking { approvals.askAbout(program) }
                return AgentError(.notAllowed, """
                    Nerda is asking the user whether \(program.name) may use it. Until they allow it, Nerda only \
                    tells it its status. Ask the user to answer Nerda's question, then try again.
                    """)
            }
        }
    }

    /// The verb's answer, or "timed out" once its deadline passes first:
    /// the verb is cancelled then, and its waits end.
    private static func done(_ verb: AgentVerb, _ call: AgentCall) async -> AgentReply {
        let work = Task { @MainActor () -> AgentReply in
            do {
                let text = try await verb.run(call)
                return .done(text, jpeg: call.shown.jpeg)
            }
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
