import Foundation
import Lab
import Testing

/// Two lab runs never go at once (`./lab.sh`): the second stops at once
/// and says which run holds the Mac.
struct LabLockTests {
    let path = FileManager.default.temporaryDirectory.appending(path: "lab-lock-\(UUID().uuidString)").path

    @Test func aSecondRunStopsSayingWhichRunIsGoing() throws {
        let first = try LabLock.take(at: path, started: Date(timeIntervalSince1970: 1_795_000_000))
        defer { first.release() }
        let refused = #expect(throws: LabLock.Busy.self) { try LabLock.take(at: path) }
        let said = refused.map { "\($0)" } ?? ""
        #expect(said.contains("Another lab run is going"))
        #expect(said.contains("process \(getpid())"))
        #expect(said.contains("stops here"))
    }

    @Test func theNextRunGoesOnceTheFirstIsDone() throws {
        try LabLock.take(at: path).release()
        try LabLock.take(at: path).release()
    }
}
