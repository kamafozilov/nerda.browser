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
    let clock = ContinuousClock()
    var budget = WaitBudget(timeout: timeout)
    while true {
        let looked = clock.now
        if try await condition() { return }
        let slept = clock.now
        guard !budget.isOver else { break }
        try await Task.sleep(for: WaitBudget.look)
        let excused = budget.excused
        budget.spend(looking: slept - looked, sleeping: clock.now - slept)
        if budget.excused > excused {
            print("waitFor at \(sourceLocation): the main thread stalled, \(budget.excused - excused) not counted")
        }
    }
    try #require(try await condition(), "\(comment.rawValue) (\(budget.excused) of main thread stalls not counted)", sourceLocation: sourceLocation)
}

/// How much of a wait's limit its steps have used: the time spent looking
/// and the time asleep between looks, but for a look that came back a stall
/// late (`Watchdog.threshold`, a second or more): only its own 20 ms count,
/// until as much has been let off as the limit itself.
struct WaitBudget {
    static let look = Duration.milliseconds(20)
    static let stall = Duration.seconds(Watchdog.threshold)

    let timeout: Duration
    private(set) var spent = Duration.zero
    private(set) var excused = Duration.zero

    init(timeout: Duration) { self.timeout = timeout }

    var isOver: Bool { spent >= timeout }

    mutating func spend(looking: Duration, sleeping: Duration) {
        spent += looking
        let late = sleeping - Self.look
        let letOff = late >= Self.stall ? min(late, timeout - excused) : .zero
        excused += letOff
        spent += sleeping - letOff
    }
}
