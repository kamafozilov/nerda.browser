import Foundation
import Testing
@testable import Nerda

/// Waits for `condition`, looking again every 20 ms for up to `timeout`:
/// a state that never comes fails the test where it was waited for, rather
/// than leaving the run hanging. A stall of the main thread meanwhile, when
/// nothing a test waits on there could happen, isn't counted, up to the
/// limit once more (`WaitBudget`): WebKit, starting a page's process while
/// many start, has held it up for five seconds in the kernel. Each stall
/// let off is printed, and a wait that fails says how much was.
@MainActor
func waitFor(_ comment: Comment = "Timed out waiting", timeout: Duration = .seconds(6),
             sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool) async throws {
    let budget = WaitBudget(timeout: timeout)
    let start = ContinuousClock.now
    var stalled = Duration.zero
    func isOver() -> Bool {
        stalled = MainStalls.during(start, ContinuousClock.now)
        return budget.isOver(after: ContinuousClock.now - start, stalled: stalled)
    }
    while try await !condition() {
        // A stall that just ended is noted at its loop's next step: one more look after that.
        if isOver() {
            try await Task.sleep(for: .milliseconds(20))
            if isOver() { break }
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let letOff = budget.letOff(stalled)
    if letOff > .zero { print("waitFor at \(sourceLocation): the main thread stalled, \(letOff) not counted") }
    try #require(try await condition(), "\(comment.rawValue) (\(letOff) of main thread stalls not counted)", sourceLocation: sourceLocation)
}

/// A wait's limit: the time it took, less the main thread's stalls
/// meanwhile, up to as much as the limit itself, so a wait that never comes
/// true still ends.
struct WaitBudget {
    let timeout: Duration

    func letOff(_ stalled: Duration) -> Duration { min(stalled, timeout) }

    func isOver(after elapsed: Duration, stalled: Duration) -> Bool {
        elapsed - letOff(stalled) >= timeout
    }
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
