import Foundation
import Network
import Testing
@testable import Nerda

/// A filter list server that answers 304 when asked for the version it has.
@MainActor
private final class ListServer {
    var version = "v1"
    var full = 0
    var unchanged = 0
    let listener: NWListener

    var body: String { "[Adblock Plus 2.0]\n||ads-\(version).example^\n" }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let response = MainActor.assumeIsolated {
                    let request = String(decoding: data ?? Data(), as: UTF8.self).lowercased()
                    if request.contains("if-none-match: \"\(self.version)\"") {
                        self.unchanged += 1
                        return "HTTP/1.1 304 Not Modified\r\nETag: \"\(self.version)\"\r\nConnection: close\r\n\r\n"
                    }
                    self.full += 1
                    return "HTTP/1.1 200 OK\r\nETag: \"\(self.version)\"\r\nContent-Length: \(self.body.utf8.count)\r\nConnection: close\r\n\r\n" + self.body
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func url() async throws -> URL {
        for _ in 0..<100 where listener.port == nil || listener.port == .any { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(listener.port?.rawValue)
        return URL(string: "http://127.0.0.1:\(port)/list.txt")!
    }
}

/// A list unchanged since it was fetched comes back as a 304, not the whole
/// list again; a changed one is fetched whole, and one that can't be had is
/// used as kept.
@MainActor
@Test func blockListsAreFetchedOnlyWhenChanged() async throws {
    let server = try ListServer()
    defer { server.listener.cancel() }
    let url = try await server.url()
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cached = folder.appending(path: "list")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
    #expect((server.full, server.unchanged) == (1, 1))
    // Not due: the copy kept, nothing asked.
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: false, session: session) == server.body)
    #expect((server.full, server.unchanged) == (1, 1))

    server.version = "v2"
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
    #expect((server.full, server.unchanged) == (2, 1))
    #expect(try String(contentsOf: cached, encoding: .utf8) == server.body)

    server.listener.cancel()
    #expect(await Blocker.list(from: url, keptIn: cached, fetch: true, session: session) == server.body)
}

/// Compiling is skipped only for the same lists turned into rules by the same build.
@Test func compiledListsAreKnownByTheirTextAndBuild() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appending(path: "Nerda")
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: executable.path)
    let lists = "||ads.example^\n"
    let digest = Blocker.compiledDigest(of: lists, by: executable)
    #expect(Blocker.compiledDigest(of: lists, by: executable) == digest)
    #expect(Blocker.compiledDigest(of: lists + "||more.example^\n", by: executable) != digest)
    // A new build. A new URL too: a URL keeps the dates it has read, and
    // each helper is a new process anyway.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: executable.path)
    #expect(Blocker.compiledDigest(of: lists, by: URL(filePath: executable.path)) != digest)
}
