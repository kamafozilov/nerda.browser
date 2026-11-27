import Darwin
import Foundation

/// One test at a time on this Mac floats a video (Picture in Picture): the
/// system's floating window is one for the whole Mac, so two runs side by
/// side, or two tests of one run, would float into each other's. Held from
/// before the first float to after the last landing:
///
///     let lock = try await FloatingLock.take()
///     defer { lock.release() }
///
/// An exclusive `flock` on a file each holder opens anew, so it keeps two
/// tests of one run apart as it does two runs, and goes with the process
/// should a run be killed holding it. Waited for off the main thread,
/// which goes on meanwhile.
public final class FloatingLock: Sendable {
    /// The same for every run and every worktree on this Mac.
    public static let path = "/tmp/dev.nerda.tests.floating.lock"

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// The lock, once no other holds it.
    public static func take(at path: String = path) async throws -> FloatingLock {
        let descriptor = try open(path)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
                done.resume()
            }
        }
        return FloatingLock(descriptor: descriptor)
    }

    /// The lock if nobody holds it now, else nil.
    public static func taken(at path: String = path) throws -> FloatingLock? {
        let descriptor = try open(path)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return FloatingLock(descriptor: descriptor)
    }

    private static func open(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    /// Let go of, for the next to float.
    public func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
