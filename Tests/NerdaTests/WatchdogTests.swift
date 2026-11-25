import Foundation
import Testing
@testable import Nerda

/// Where the main thread stopped (Watchdog): a stall of a second or more is
/// written down with the main thread's stack, and a main loop that keeps
/// moving never wakes the watchdog. Each test has a watchdog of its own,
/// writing to a file of its own, never the data folder's.
@MainActor
@Suite(.serialized)
struct WatchdogTests {
    private func watching() -> (Watchdog, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "stalls-\(UUID().uuidString).log")
        let watchdog = Watchdog(file: file, recorder: Recorder())
        watchdog.start()
        return (watchdog, file)
    }

    private func log(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    @Test func aStallOfASecondIsWrittenWithItsStack() async throws {
        let (watchdog, file) = watching()
        defer { watchdog.stop(); try? FileManager.default.removeItem(at: file) }
        // A pass of its own, begun after the watchdog was watching.
        try await Task.sleep(for: .milliseconds(50))
        usleep(1_200_000)
        try await waitFor { log(file).contains("  stall ") }
        let text = log(file)
        #expect(text.contains("stalling"), "the stall was seen while it lasted")
        // Its frames: the binary and the offset in it, the tests' own among them.
        let frames = text.split(separator: "\n").filter { $0.hasPrefix("    ") && $0.contains(" +0x") }
        #expect(frames.contains { $0.contains("Nerda") }, "with where the main thread was: \(text)")
        #expect(!text.contains("ended before"))
    }

    @Test func aLoopThatKeepsMovingNeverWakesIt() async throws {
        let (watchdog, file) = watching()
        defer { watchdog.stop(); try? FileManager.default.removeItem(at: file) }
        // Two and a half seconds of a busy main loop, as an animation keeps
        // it: 40 ms of work in each pass, never a second without a step.
        let end = Date.now.addingTimeInterval(2.5)
        while Date.now < end {
            let pass = Date.now.addingTimeInterval(0.04)
            while Date.now < pass {}
            try await Task.sleep(for: .milliseconds(2))
        }
        try await Task.sleep(for: .milliseconds(200))
        // Another test may stall the main thread meanwhile: the watchdog
        // may wake only for a stall it writes down.
        let stalls = log(file).components(separatedBy: "stalling").count - 1
        #expect(watchdog.wakes == stalls)
    }
}
