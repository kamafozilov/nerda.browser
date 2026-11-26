import Darwin
import Foundation
import os

/// The Unix socket agents reach the app on, both ends of it: the app's
/// listener (`Listener`) and the shim's one request (`request`). Plain BSD
/// sockets, for the peer's user id and audit token, which Network.framework
/// doesn't give. Nothing here runs on the main thread: connections are read
/// and answered on queues of their own, and only the verb itself goes to
/// the main thread (`AgentServer`).
nonisolated enum AgentSocket {
    enum Failure: Error, Equatable {
        /// Nothing listens there: Nerda isn't running, or agents are off.
        case unreachable
        /// The path is longer than a socket's address holds.
        case pathTooLong
        /// Another Nerda of the same edition already listens there.
        case inUse
        /// No answer before the time ran out.
        case timedOut
        case system(Int32)
    }

    // MARK: The shim's side

    /// Sends `request` as one line to the app at `path` and reads its whole
    /// answer, waiting at most `timeout` for it. Blocking calls on a queue of
    /// their own, so many requests can wait at once.
    static func request(_ request: Data, to path: String, timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try requestNow(request, to: path, timeout: timeout) })
            }
        }
    }

    private static func requestNow(_ request: Data, to path: String, timeout: Duration) throws -> Data {
        let fd = try connect(to: path)
        defer { Darwin.close(fd) }
        setTimeout(fd, SO_SNDTIMEO, AgentWire.requestTimeout)
        setTimeout(fd, SO_RCVTIMEO, timeout)
        try write(request + Data("\n".utf8), to: fd)
        // The app answers, then closes: everything up to the end is the answer.
        return try read(fd, upTo: AgentWire.maxReply, line: false)
    }

    private static func connect(to path: String) throws -> Int32 {
        var address = try address(of: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let error = errno
            Darwin.close(fd)
            throw [ENOENT, ECONNREFUSED].contains(error) ? Failure.unreachable : Failure.system(error)
        }
        return fd
    }

    // MARK: The app's side

    /// One caller connected: its socket, user id and audit token. The
    /// handler reads the request, answers once, and the connection closes.
    final class Connection: @unchecked Sendable {
        let fd: Int32
        let uid: uid_t
        /// The caller's audit token, to check its code signature by
        /// (`AgentCallers`); nil if the system didn't give one.
        let token: Data?
        private let closed = OSAllocatedUnfairLock(initialState: false)

        init(fd: Int32) {
            self.fd = fd
            var uid = uid_t.max, gid = gid_t.max
            if getpeereid(fd, &uid, &gid) != 0 { uid = .max }
            self.uid = uid
            var token = audit_token_t()
            var length = socklen_t(MemoryLayout<audit_token_t>.size)
            self.token = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0
                ? withUnsafeBytes(of: &token) { Data($0) } : nil
        }

        /// The request line, or nil when the caller sent none in time, or
        /// one too long.
        func readRequest() -> Data? {
            try? AgentSocket.read(fd, upTo: AgentWire.maxRequest, line: true)
        }

        /// Writes the answer and closes. A caller that stops reading is
        /// dropped once the send times out.
        func answer(_ data: Data) {
            try? AgentSocket.write(data, to: fd)
            close()
        }

        func close() {
            let wasOpen = closed.withLock { closed in
                defer { closed = true }
                return !closed
            }
            if wasOpen { Darwin.close(fd) }
        }
    }

    /// The app listening at a path: owner-only, a large backlog, each caller
    /// handed to `handle` on a queue of its own.
    final class Listener: @unchecked Sendable {
        let path: String
        private let fd: Int32
        private let source: DispatchSourceRead
        private static let accepting = DispatchQueue(label: "dev.nerda.agents.accept")
        private static let connections = DispatchQueue(label: "dev.nerda.agents.connections", attributes: .concurrent)

        init(path: String, handle: @escaping @Sendable (Connection) -> Void) throws {
            self.path = path
            var address = try AgentSocket.address(of: path)
            // A socket left by a Nerda that crashed answers nothing: it goes.
            // One that answers is another Nerda of this edition's, kept.
            if let other = try? AgentSocket.connect(to: path) {
                Darwin.close(other)
                throw Failure.inUse
            }
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.system(errno) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            // Only the owner's user may connect; the caller check (`AgentCallers`) looks again.
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 256) == 0 else {
                let error = errno
                Darwin.close(fd)
                unlink(path)
                throw Failure.system(error)
            }
            self.fd = fd
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.accepting)
            source.setEventHandler {
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                    var on: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    AgentSocket.setTimeout(client, SO_RCVTIMEO, AgentWire.requestTimeout)
                    AgentSocket.setTimeout(client, SO_SNDTIMEO, AgentWire.requestTimeout)
                    let connection = Connection(fd: client)
                    Self.connections.async { handle(connection) }
                }
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
        }

        /// Stops listening and takes the socket file away, so callers find
        /// nothing there. Calls already taken are still answered.
        func close() {
            guard !source.isCancelled else { return }
            source.cancel()
            unlink(path)
        }

        deinit { close() }
    }

    // MARK: Both

    static func address(of path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < room else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func setTimeout(_ fd: Int32, _ option: Int32, _ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        setsockopt(fd, SOL_SOCKET, option, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? Failure.timedOut : Failure.system(errno)
                }
                offset += written
            }
        }
    }

    /// Reads up to the first newline (`line`) or to the end, failing past
    /// `limit` bytes or when the socket's receive time runs out.
    static func read(_ fd: Int32, upTo limit: Int, line: Bool) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? Failure.timedOut : Failure.system(errno)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if line, let end = data.firstIndex(of: UInt8(ascii: "\n")) { return data[..<end] }
            guard data.count <= limit else { throw Failure.system(EMSGSIZE) }
        }
    }
}
