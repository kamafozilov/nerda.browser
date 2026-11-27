import Foundation
import Testing
import MediaCheck

/// The lock floating tests take (`FloatingLock`) keeps out every other
/// holder, in this process as in another, until it is let go.
@Test func theFloatingLockHasOneHolderAtATime() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "floating-\(UUID().uuidString).lock").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let first = try await FloatingLock.take(at: path)
    #expect(try FloatingLock.taken(at: path) == nil)
    let child = Process()
    // Another process: `lockf -t 0` fails at once on a file held with flock.
    child.executableURL = URL(filePath: "/usr/bin/lockf")
    child.arguments = ["-k", "-t", "0", path, "/usr/bin/true"]
    try child.run()
    child.waitUntilExit()
    #expect(child.terminationStatus != 0)
    first.release()
    let second = try #require(try FloatingLock.taken(at: path))
    second.release()
}
