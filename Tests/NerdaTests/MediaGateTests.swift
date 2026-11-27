import Testing
@testable import Nerda

/// Who plays media in a run (`MediaGate`): beds share it, one that reaches
/// every page holds it alone, and each waits its turn. On a gate of the
/// test's own, not the run's.
@MainActor
struct MediaGateTests {
    @Test func aHoldAloneWaitsForThoseSharing() async throws {
        let gate = MediaGate()
        let first = await gate.shared(), second = await gate.shared()
        var order: [String] = []
        let alone = Task { let hold = await gate.alone(); order.append("alone"); return hold }
        try await waitFor { gate.waitingCount == 1 }
        first.release()
        order.append("first released")
        second.release()
        order.append("second released")
        let held = await alone.value
        #expect(order == ["first released", "second released", "alone"])
        held.release()
    }

    /// One waiting to hold it alone keeps nobody from sharing: a test with
    /// a bed open may open another, and waiting, would never close the first.
    @Test func sharingGoesOnWhileOneWaitsToHoldItAlone() async throws {
        let gate = MediaGate()
        let first = await gate.shared()
        let alone = Task { await gate.alone() }
        try await waitFor { gate.waitingCount == 1 }
        let second = await gate.shared()
        first.release()
        #expect(gate.waitingCount == 1)
        second.release()
        (await alone.value).release()
        #expect(gate.waitingCount == 0)
    }

    /// Held alone, it keeps everyone else waiting until let go.
    @Test func aHoldAloneKeepsThoseSharingWaiting() async throws {
        let gate = MediaGate()
        let alone = await gate.alone()
        var shared = false
        let later = Task { let hold = await gate.shared(); shared = true; return hold }
        try await waitFor { gate.waitingCount == 1 }
        #expect(!shared)
        alone.release()
        (await later.value).release()
        #expect(shared)
    }
}
