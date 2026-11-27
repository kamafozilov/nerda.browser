import Darwin
import Foundation

/// One lab run at a time on this Mac: its steps on screen and its sound
/// would spoil another's. An exclusive `flock` on one file, taken without
/// waiting, so a second run stops at once with who holds it; the kernel
/// lets go of it should a run die.
public final class LabLock: Sendable {
    /// The same for every worktree on this Mac.
    public static let path = "/tmp/dev.nerda.lab.lock"

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Another run holds the lock.
    public struct Busy: Error, CustomStringConvertible {
        public var holder: String
        public var description: String {
            "Another lab run is going (\(holder.isEmpty ? "its process unknown" : holder)): this one stops here. "
                + "Run it again once that one is done."
        }
    }

    /// The lock, or `Busy` if another run has it. The holder's process and
    /// start are written into the file for the next to read.
    public static func take(at path: String = path, started: Date = Date()) throws -> LabLock {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            close(descriptor)
            throw Busy(holder: holder)
        }
        let holder = "process \(getpid()), started \(ISO8601DateFormatter().string(from: started))\n"
        ftruncate(descriptor, 0)
        _ = holder.withCString { pwrite(descriptor, $0, strlen($0), 0) }
        return LabLock(descriptor: descriptor)
    }

    public func release() {
        ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
