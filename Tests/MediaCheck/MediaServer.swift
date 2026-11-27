import Foundation
import Network
import Synchronization

/// Media and its pages served on this Mac for the media test bed, as the
/// agent tests' pages are (`AgentTestPages`), but with what a player asks
/// of a server: any content type, parts of a file (`Range`), and answers on
/// a queue of the server's own, so a test holding the main thread doesn't
/// hold the media up. Every request is kept, its first line and its range.
public final class MediaServer: Sendable {
    public struct Body: Sendable {
        public var data: Data
        public var type: String

        public init(data: Data, type: String) {
            self.data = data
            self.type = type
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MediaServer")
    private let routes = Mutex<[String: Body]>([:])
    private let asked = Mutex<[String]>([])

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.read(connection, Data())
        }
        listener.start(queue: queue)
    }

    /// Serves `data` as `type` at `path`, and answers its address.
    @discardableResult
    @MainActor
    public func serve(_ path: String, _ data: Data, type: String) async throws -> URL {
        routes.withLock { $0[path] = Body(data: data, type: type) }
        return try await url(path)
    }

    @discardableResult
    @MainActor
    public func serve(_ path: String, html: String) async throws -> URL {
        try await serve(path, Data(html.utf8), type: "text/html; charset=utf-8")
    }

    @MainActor
    public func url(_ path: String = "/") async throws -> URL {
        let deadline = ContinuousClock.now + .seconds(6)
        while listener.port == nil || listener.port == .any {
            guard ContinuousClock.now < deadline else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The media server never listened"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    /// The requests so far: `GET /media/movie.mp4 bytes=0-1`.
    public var requests: [String] { asked.withLock { $0 } }

    public func stop() { listener.cancel() }

    /// Reads until the request's head is whole, then answers it.
    private func read(_ connection: NWConnection, _ head: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            let head = head + (data ?? Data())
            if head.range(of: Data("\r\n\r\n".utf8)) != nil { return answer(connection, String(decoding: head, as: UTF8.self)) }
            if done || error != nil { return connection.cancel() }
            read(connection, head)
        }
    }

    private func answer(_ connection: NWConnection, _ request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let words = lines[0].split(separator: " ").map(String.init)
        let method = words.first ?? "GET", path = (words.dropFirst().first ?? "/").components(separatedBy: "?")[0]
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        asked.withLock { $0.append([method, path, range].compactMap(\.self).joined(separator: " ")) }

        var status = "200 OK", headers = ["Accept-Ranges: bytes", "Cache-Control: no-store", "Connection: close"]
        var content = Data()
        if let body = routes.withLock({ $0[path] }) {
            headers.append("Content-Type: \(body.type)")
            content = body.data
            if let range, let (start, end) = Self.bytes(range, of: body.data.count) {
                status = "206 Partial Content"
                headers.append("Content-Range: bytes \(start)-\(end)/\(body.data.count)")
                content = body.data.subdata(in: start..<end + 1)
            } else if range != nil {
                status = "416 Range Not Satisfiable"
                headers.append("Content-Range: bytes */\(body.data.count)")
                content = Data()
            }
        } else {
            status = "404 Not Found"
            headers.append("Content-Type: text/plain")
            content = Data("Nothing here".utf8)
        }
        headers.append("Content-Length: \(content.count)")
        let reply = Data("HTTP/1.1 \(status)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8) + (method == "HEAD" ? Data() : content)
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The first and last byte `bytes=a-b`, `bytes=a-` or `bytes=-n` asks
    /// for, within `count`; nil when it asks for none of them.
    public static func bytes(_ range: String, of count: Int) -> (Int, Int)? {
        guard range.hasPrefix("bytes="), !range.contains(",") else { return nil }
        let ends = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard ends.count == 2 else { return nil }
        let (start, end): (Int, Int) = switch (ends[0], ends[1]) {
        case let (start?, end?): (start, min(end, count - 1))
        case let (start?, nil): (start, count - 1)
        case let (nil, last?): (max(count - last, 0), count - 1)
        case (nil, nil): (count, -1)
        }
        return start <= end && start < count ? (start, end) : nil
    }
}
