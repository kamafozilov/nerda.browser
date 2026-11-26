import Testing
@testable import Nerda

/// What a wait (`waitFor`) counts against its limit: everything, but a
/// look that came back a stall late, which it lets off up to its limit
/// once more. Fed the lengths of a wait's steps, no time passes.
struct WaitingTests {
    @Test func aStallOfTheMainThreadIsLetOff() {
        var budget = WaitBudget(timeout: .seconds(6))
        budget.spend(looking: .zero, sleeping: .milliseconds(5020))
        #expect(budget.excused == .seconds(5))
        #expect(budget.spent == .milliseconds(20))
        #expect(!budget.isOver)
    }

    @Test func aBusyMainThreadIsCounted() {
        var budget = WaitBudget(timeout: .seconds(6))
        budget.spend(looking: .zero, sleeping: .milliseconds(900))
        #expect(budget.excused == .zero)
        #expect(budget.spent == .milliseconds(900))
    }

    @Test func theConditionsOwnTimeIsCounted() {
        var budget = WaitBudget(timeout: .seconds(6))
        budget.spend(looking: .seconds(2), sleeping: .milliseconds(20))
        #expect(budget.spent == .milliseconds(2020))
    }

    @Test func noMoreThanTheLimitIsLetOff() {
        var budget = WaitBudget(timeout: .seconds(2))
        budget.spend(looking: .zero, sleeping: .seconds(5))
        #expect(budget.excused == .seconds(2))
        #expect(budget.isOver)
        budget = WaitBudget(timeout: .seconds(2))
        budget.spend(looking: .zero, sleeping: .milliseconds(1520))
        budget.spend(looking: .zero, sleeping: .milliseconds(1520))
        #expect(budget.excused == .seconds(2))
        #expect(budget.spent == .milliseconds(1040))
    }
}
