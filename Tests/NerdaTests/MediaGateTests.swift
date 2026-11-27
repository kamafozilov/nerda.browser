import Testing
@testable import Nerda

/// Who plays media in a run (`MediaGate`): beds share it, one that reaches
/// every page holds it alone, and each waits its turn. On a gate of the
/// test's own, not the run's.
@MainActor
struct MediaGateTests {
    @Test func aHoldAloneWaitsForThoseSharingAndKeepsLaterOnesWaiting() async throws {
        let gate = MediaGate()
        let first = await gate.shared(), second = await gate.shared()
        var order: [String] = []
        let alone = Task { let hold = await gate.alone(); order.append("alone"); return hold }
        try await waitFor { gate.waitingCount == 1 }
        let later = Task { let hold = await gate.shared(); order.append("later"); return hold }
        try await waitFor { gate.waitingCount == 2 }
        first.release()
        order.append("first released")
        second.release()
        order.append("second released")
        let held = await alone.value
        try await waitFor { order.count == 3 }
        #expect(order == ["first released", "second released", "alone"])
        held.release()
        (await later.value).release()
        #expect(order == ["first released", "second released", "alone", "later"])
    }
}
