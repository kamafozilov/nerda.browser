import Foundation
import Network
import Testing
import WebKit
@testable import Nerda

/// The one seam agent tests go through (spec #119, Testing Decisions): MCP
/// JSON-RPC into the shim's in-process entry point (`AgentMCP`), over a real
/// Unix socket in a temporary folder, to an agent server in the test process
/// holding a real `AgentBrowser` on a non-persistent data store, its window
/// off screen, with pages from a local HTTP server.
///
///     let harness = try AgentHarness()
///     defer { harness.close() }
///     let url = try await harness.pages.serve("/account", "<title>Account</title><p>Signed in</p>")
///     let agent = try await harness.agent()
///     let answer = try await agent.call("open", ["url": url])
///     #expect(answer.text.contains("Signed in"))
@MainActor
final class AgentHarness {
    let folder: URL
    let pages: AgentTestPages
    let server: AgentServer
    /// Settings of the test's own, for the switch that lets agents in.
    let defaults: UserDefaults
    /// The server's awake time, moved by hand (`advance(by:)`).
    let clock = AgentTestClock()
    private let defaultsName: String
    var socket: URL { server.socket }

    /// `callers` decides who may do more than ask for status; by default
    /// every program of this user, as in development builds.
    init(callers: AgentCallers = .anyone) throws {
        // Short: a socket's path has room for 103 bytes.
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "na-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pages = try AgentTestPages()
        defaultsName = "nerda.agents.tests." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        // Every profile's Agent tabs on a store of their own, kept in memory.
        let clock = clock
        server = AgentServer(socket: folder.appending(path: "agents.sock"), callers: callers, defaults: defaults,
                             now: { clock.now }) { profile in
            AgentBrowser(profile: profile, dataStore: .nonPersistent())
        }
        server.start()
    }

    /// The Agent browser the server opened Agent tabs in, once it has.
    var agents: AgentBrowser? { server.browsers.first }

    /// An MCP client connected to the server through the shim, as Claude
    /// Code or Codex would be, already past `initialize`. `session` is the
    /// harness's session id (Claude Code's, Codex's thread's).
    func agent(client: String = "claude-code", session: String = "session-1",
               wire: Int = AgentWire.version) async throws -> AgentTestClient {
        let mcp = AgentMCP(socket: socket, environment: ["CLAUDE_CODE_SESSION_ID": session], wire: wire)
        let agent = AgentTestClient(mcp: mcp)
        let reply = try await agent.request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": .string(client), "version": "1.0"],
        ])
        #expect(reply["result"]?["serverInfo"]?["name"]?.string == "nerda-browser")
        _ = await mcp.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return agent
    }

    func close() {
        server.stop()
        for browser in server.browsers { browser.close() }
        pages.stop()
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Awake time that only moves when a test moves it, so cleanup's 15
/// minutes pass at once.
@MainActor
final class AgentTestClock {
    private(set) var now = SuspendingClock.now

    func advance(by duration: Duration) { now = now.advanced(by: duration) }
}

/// One MCP client's side of the conversation with the shim.
struct AgentTestClient {
    let mcp: AgentMCP
    private static let ids = Counter()

    /// A JSON-RPC request and its whole reply (`result` or `error`).
    func request(_ method: String, _ params: AgentJSON = [:]) async throws -> AgentJSON {
        let id = Self.ids.next()
        let message: AgentJSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let line = try #require(await mcp.reply(to: message.line))
        let reply = try AgentJSON(line: line)
        #expect(reply["id"]?.number == Double(id))
        return reply
    }

    /// A tool called, and the text it answered, with whether it failed.
    func call(_ tool: String, _ arguments: [String: AgentJSON] = [:]) async throws -> (text: String, isError: Bool) {
        let reply = try await request("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
        let result = try #require(reply["result"], "No result: \(reply.line)")
        let text = result["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
        return (text, result["isError"]?.bool ?? false)
    }

    /// The tools the shim lists, by name.
    func tools() async throws -> [AgentJSON] {
        try #require(try await request("tools/list")["result"]?["tools"]?.array)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Pages served on this Mac for agent tests: each path its own HTML, every
/// request kept. `http://127.0.0.1` and `http://localhost` on the same port
/// are two sites, for frames from another site.
@MainActor
final class AgentTestPages {
    private let listener: NWListener
    private var routes: [String: String] = [:]
    private(set) var requests: [String] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                MainActor.assumeIsolated {
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    self?.requests.append(request)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let body = self?.routes[path.components(separatedBy: "?")[0]]
                    let status = body == nil ? "404 Not Found" : "200 OK"
                    let content = body ?? "<title>Not found</title><p>Nothing here</p>"
                    let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.utf8.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data((head + content).utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }

    /// Serves `html` at `path`, and answers its address.
    @discardableResult
    func serve(_ path: String, _ html: String, host: String = "127.0.0.1") async throws -> URL {
        routes[path] = html
        return try await url(path, host: host)
    }

    func url(_ path: String = "/", host: String = "127.0.0.1") async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://\(host):\(try #require(listener.port).rawValue)\(path)")!
    }

    /// The requests for `path`, with their headers.
    func requests(for path: String) -> [String] { requests.filter { $0.hasPrefix("GET \(path) ") } }

    func stop() { listener.cancel() }
}

extension AgentJSON {
    /// A URL as an argument.
    init(_ url: URL) { self = .string(url.absoluteString) }
}
