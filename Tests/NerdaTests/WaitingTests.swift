import Testing
@testable import Nerda

/// What a wait (`waitFor`) counts against its limit: the time it took,
/// less the main thread's stalls meanwhile, up to the limit once more.
struct WaitingTests {
    private let budget = WaitBudget(timeout: .seconds(6))

    @Test func aStallOfTheMainThreadIsLetOff() {
        #expect(!budget.isOver(after: .seconds(10), stalled: .seconds(5)))
        #expect(budget.isOver(after: .seconds(11), stalled: .seconds(5)))
    }

    @Test func aWaitWithoutAStallTakesItsLimit() {
        #expect(!budget.isOver(after: .milliseconds(5990), stalled: .zero))
        #expect(budget.isOver(after: .seconds(6), stalled: .zero))
    }

    @Test func noMoreThanTheLimitIsLetOff() {
        #expect(budget.letOff(.seconds(20)) == .seconds(6))
        #expect(budget.isOver(after: .seconds(12), stalled: .seconds(20)))
    }
}
