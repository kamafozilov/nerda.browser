import Foundation
import Network
import Synchronization

/// Where Nerda Test asks what to do next (`Lab.Client` in Nerda): a local
/// HTTP server on 127.0.0.1. `GET /lab/next` is held until there is a
/// command (or answered 204 after a while, and asked again); `POST
/// /lab/done` brings the answer. Nerda Test opens nothing to be asked:
/// it is the one asking.
final class Channel: Sendable {
    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    /// A JSON value as Foundation gives it.
    struct JSON: @unchecked Sendable {
        var value: Any
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Channel")

    private struct State {
        var commands: [Data] = []
        var waiting: [NWConnection] = []
        var answers: [Int: CheckedContinuation<JSON, any Error>] = [:]
        var next = 1
        var pid: pid_t?
        var asked = Date.distantPast
    }

    private let state = Mutex(State())

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.read(connection, Data())
        }
        listener.start(queue: queue)
    }

    /// The address to give Nerda Test.
    func address() async throws -> URL {
        let deadline = Date().addingTimeInterval(6)
        while listener.port == nil || listener.port == .any {
            guard Date() < deadline else { throw Failed(description: "the lab's channel never listened") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/lab")!
    }

    /// Nerda Test's process, once it has asked.
    var pid: pid_t? { state.withLock { $0.pid } }
    /// When Nerda Test last asked for a command.
    var lastAsked: Date { state.withLock { $0.asked } }

    func stop() { listener.cancel() }

    /// Sends `op` with `parameters` and waits up to `timeout` seconds for
    /// Nerda Test's answer: its value, or what went wrong.
    func send(_ op: String, _ parameters: [String: Any] = [:], timeout: Double = 30) async throws -> JSON {
        try await withThrowingTaskGroup(of: JSON.self) { group in
            let id = state.withLock { state in
                defer { state.next += 1 }
                return state.next
            }
            var command = parameters
            command["id"] = id
            command["op"] = op
            let data = (try? JSONSerialization.data(withJSONObject: command)) ?? Data()
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let connection = self.state.withLock { state -> NWConnection? in
                        state.answers[id] = continuation
                        if state.waiting.isEmpty {
                            state.commands.append(data)
                            return nil
                        }
                        state.commands.append(data)
                        return state.waiting.removeFirst()
                    }
                    if let connection { self.queue.async { self.deliver(to: connection) } }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Failed(description: "Nerda Test didn't answer \(op) in \(Int(timeout)) s")
            }
            defer {
                group.cancelAll()
                if let continuation = state.withLock({ $0.answers.removeValue(forKey: id) }) {
                    continuation.resume(throwing: Failed(description: "Nerda Test didn't answer \(op) in \(Int(timeout)) s"))
                }
            }
            return try await group.next()!
        }
    }

    // MARK: - HTTP

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            let received = received + (data ?? Data())
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = received[end.upperBound...]
                if body.count >= length { return answer(connection, head, Data(body.prefix(length))) }
            }
            if done || error != nil { return connection.cancel() }
            read(connection, received)
        }
    }

    private func answer(_ connection: NWConnection, _ head: String, _ body: Data) {
        let words = head.components(separatedBy: "\r\n")[0].split(separator: " ").map(String.init)
        let target = words.dropFirst().first ?? "/"
        let path = target.components(separatedBy: "?")[0]
        switch path {
        case "/lab/next":
            let pid = URLComponents(string: target)?.queryItems?.first { $0.name == "pid" }?.value.flatMap { pid_t($0) }
            let ready = state.withLock { state -> Bool in
                if let pid { state.pid = pid }
                state.asked = Date()
                if state.commands.isEmpty { state.waiting.append(connection) }
                return !state.commands.isEmpty
            }
            if ready { return deliver(to: connection) }
            // Held a while, then let go: Nerda Test asks again at once.
            queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, state.withLock({ state in
                    guard let index = state.waiting.firstIndex(where: { $0 === connection }) else { return false }
                    state.waiting.remove(at: index)
                    return true
                }) else { return }
                send(connection, status: "204 No Content", Data())
            }
        case "/lab/done":
            send(connection, status: "200 OK", Data("{}".utf8))
            guard let answer = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = answer["id"] as? Int,
                  let continuation = state.withLock({ $0.answers.removeValue(forKey: id) }) else { return }
            if answer["ok"] as? Bool == true {
                continuation.resume(returning: JSON(value: answer["value"] ?? NSNull()))
            } else {
                continuation.resume(throwing: Failed(description: answer["error"] as? String ?? "Nerda Test said it failed"))
            }
        default:
            send(connection, status: "404 Not Found", Data())
        }
    }

    private func deliver(to connection: NWConnection) {
        guard let command = state.withLock({ $0.commands.isEmpty ? nil : $0.commands.removeFirst() }) else {
            state.withLock { $0.waiting.append(connection) }
            return
        }
        send(connection, status: "200 OK", command)
    }

    private func send(_ connection: NWConnection, status: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
