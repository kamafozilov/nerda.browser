import Foundation
import Testing
@testable import Nerda

/// Where the main thread stopped (Watchdog): a stall of a second or more is
/// written down with the main thread's stack, and a main loop that keeps
/// moving never wakes the watchdog. Each test has a watchdog of its own,
/// writing to a file of its own, never the data folder's. The stalls are
/// made on a thread of the test's own with its run loop, watched in the
/// main thread's place: a test that held the main thread up for seconds
/// would hold up every other test. Only the main loop's hitches, a tenth
/// of a second, are made on the main thread.
@MainActor
@Suite(.serialized)
struct WatchdogTests {
    private func watching(_ thread: LoopThread) async -> (Watchdog, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "stalls-\(UUID().uuidString).log")
        let watchdog = Watchdog(file: file, recorder: Recorder())
        await thread.run { watchdog.start { _ in } }
        return (watchdog, file)
    }

    private func log(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    @Test func aStallOfASecondIsWrittenWithItsStack() async throws {
        let thread = LoopThread()
        defer { thread.stop() }
        let (watchdog, file) = await watching(thread)
        defer { watchdog.stop(); try? FileManager.default.removeItem(at: file) }
        // A pass of its own, begun after the watchdog was watching.
        try await Task.sleep(for: .milliseconds(50))
        thread.perform { usleep(1_200_000) }
        try await waitFor { log(file).contains("  stall ") }
        let text = log(file)
        #expect(text.contains("stalling"), "the stall was seen while it lasted")
        // Its frames: the binary and the offset in it, the tests' own among them.
        let frames = text.split(separator: "\n").filter { $0.hasPrefix("    ") && $0.contains(" +0x") }
        #expect(frames.contains { $0.contains("Nerda") }, "with where the watched thread was: \(text)")
        #expect(!text.contains("ended before"))
    }

    /// Nerda's own watches the main loop, and keeps each hitch, a stop of
    /// a tenth of a second or more, in its record. The main thread is held
    /// up only that long: every other test waits on it meanwhile.
    @Test func theMainLoopsHitchesAreKeptInTheRecord() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "stalls-\(UUID().uuidString).log")
        let recorder = Recorder()
        let watchdog = Watchdog(file: file, recorder: recorder)
        watchdog.start()
        defer { watchdog.stop(); try? FileManager.default.removeItem(at: file) }
        // A pass of its own, begun after the watchdog was watching.
        try await Task.sleep(for: .milliseconds(50))
        usleep(150_000)
        try await waitFor("The hitch kept") { recorder.hitches().contains { $0.seconds >= 0.15 } }
    }

    @Test func aLoopThatKeepsMovingNeverWakesIt() async throws {
        let thread = LoopThread()
        defer { thread.stop() }
        let (watchdog, file) = await watching(thread)
        defer { watchdog.stop(); try? FileManager.default.removeItem(at: file) }
        // Two and a half seconds of a busy loop, as an animation keeps it:
        // 40 ms of work in each pass, never a second without a step.
        await thread.run {
            let end = Date.now.addingTimeInterval(2.5)
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 0.042, 0, 0) { timer in
                guard Date.now < end else { return CFRunLoopTimerInvalidate(timer) }
                let pass = Date.now.addingTimeInterval(0.04)
                while Date.now < pass {}
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
        try await Task.sleep(for: .milliseconds(2700))
        #expect(watchdog.wakes == 0)
        #expect(!log(file).contains("stalling"), "\(log(file))")
    }
}

/// A thread with a run loop of its own, for a watchdog to watch in the main
/// thread's place.
private final class LoopThread: @unchecked Sendable {
    private var loop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init() {
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            // A port, so the loop runs, asleep, with nothing else to do.
            RunLoop.current.add(Port(), forMode: .common)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "WatchdogTests.loop"
        thread.start()
        ready.wait()
    }

    /// `work` on the thread, in a pass of its loop, not waited for.
    func perform(_ work: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(loop)
    }

    /// `work` on the thread, once it has run.
    func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            perform { work(); done.resume() }
        }
    }

    func stop() { loop.map(CFRunLoopStop) }
}
