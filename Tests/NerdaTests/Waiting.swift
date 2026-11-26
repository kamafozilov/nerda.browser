import Foundation
import Testing
@testable import Nerda

/// Waits for `condition`, looking again every 20 ms for up to `timeout`:
/// a state that never comes fails the test where it was waited for, rather
/// than leaving the run hanging. The comment is read as the wait fails, so
/// it can say how things were then. A stall of the main thread meanwhile
/// counts like any other time; it is only told: printed as the wait ends,
/// and in the comment of a wait that fails.
@MainActor
func waitFor(_ comment: @autoclosure () -> Comment = "Timed out waiting", timeout: Duration = .seconds(6),
             sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool) async throws {
    let start = ContinuousClock.now
    let deadline = start + timeout
    while ContinuousClock.now < deadline, try await !condition() { try await Task.sleep(for: .milliseconds(20)) }
    let met = try await condition()
    let stalled = MainStalls.during(start, ContinuousClock.now)
    let told = stalled > .zero ? "the main thread stalled \(stalled) meanwhile" : nil
    if let told { print("waitFor at \(sourceLocation): \(told)") }
    try #require(met, "\(comment().rawValue)\(told.map { " (\($0))" } ?? "")", sourceLocation: sourceLocation)
}

/// The main thread's stalls in this test run, each a second or more
/// without a step of its loop (`Watchdog.threshold`), as a watchdog of the
/// tests' own sees them, writing to a file of its own.
@MainActor
enum MainStalls {
    private static var stalls: [(from: ContinuousClock.Instant, to: ContinuousClock.Instant)] = []

    private static let watchdog: Watchdog = {
        let file = FileManager.default.temporaryDirectory.appending(path: "stalls-tests-\(ProcessInfo.processInfo.processIdentifier).log")
        let watchdog = Watchdog(file: file, recorder: Recorder())
        watchdog.start { seconds in
            guard seconds >= Watchdog.threshold else { return }
            let now = ContinuousClock.now
            MainActor.assumeIsolated { stalls.append((now - .seconds(seconds), now)) }
        }
        return watchdog
    }()

    /// How long the main thread stalled between `start` and `end`.
    static func during(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Duration {
        _ = watchdog
        return stalls.reduce(.zero) { total, stall in
            let from = max(stall.from, start), to = min(stall.to, end)
            return to > from ? total + (to - from) : total
        }
    }
}
