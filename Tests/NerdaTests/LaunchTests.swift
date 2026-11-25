import AppKit
import Foundation
import Testing
@testable import Nerda

/// A launch's moments, the work it leaves for later, and what of both goes
/// with a feedback report. Each test has a launch of its own, so none of
/// them touches the app's (`Launch.current`), and keeps what it records in
/// defaults of its own, never in Nerda's.
@MainActor
struct LaunchTests {
    /// What ran, in order, and on which pass of the main run loop.
    @MainActor private final class Ran {
        var names: [String] = []
        var turns: [Int] = []

        /// Passes of the main run loop, counted from the first test that asks.
        private static var turn = 0
        private static let counting: Void = {
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeTimers.rawValue, true, 0) { _, _ in
                MainActor.assumeIsolated { Ran.turn += 1 }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }()

        init() { Self.counting }

        func callAsFunction(_ name: String) {
            names.append(name)
            turns.append(Self.turn)
        }
    }

    /// Work that waits runs only in the run loop's default mode; with the
    /// whole suite running, other tests can hold the main run loop in
    /// another mode for seconds.
    private static let patience: Duration = .seconds(20)

    private static func defaults() -> (UserDefaults, String) {
        let suite = "nerda.tests.launch.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func aLaunchKeepsEachMomentOnceFromTheProcessStart() {
        let launch = Launch.Record()
        launch.mark("main")
        launch.mark("window")
        launch.mark("window")
        #expect(launch.moments.map(\.name) == ["main", "window"])
        // The process started before this test did.
        #expect(launch.moments.allSatisfy { $0.ms > 0 })
        #expect(launch.moments[0].ms <= launch.moments[1].ms)
        #expect(launch.report.contains("main "))
        #expect(launch.report.contains("window "))
    }

    @Test func theLastLaunchesGoWithAReportNewestFirst() {
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = Date.now.addingTimeInterval(-60)
        for (index, start) in (0..<7).map({ started.addingTimeInterval(Double($0)) }).enumerated() {
            let launch = Launch.Record(start: start, keepingIn: defaults)
            launch.mark("main")
            launch.mark("page \(index)")
        }
        let report = Launch.Record(start: .now, keepingIn: defaults)
        report.mark("main")
        let lines = report.report.split(separator: "\n").filter { $0.contains("main ") }
        // This launch, then the five before it, newest first.
        #expect(lines.count == 6)
        #expect(!lines[0].contains("page"))
        #expect(lines[1].contains("page 6"))
        #expect(lines[5].contains("page 2"))
    }

    @Test func aLaunchWithoutDefaultsKeepsNothing() {
        let launch = Launch.Record(start: .now)
        launch.mark("main")
        let next = Launch.Record(start: .now)
        #expect(next.report.split(separator: "\n").filter { $0.contains("main ") }.isEmpty)
    }

    @Test func workThatCanWaitStartsAfterTheFirstPageOnePieceATurn() async throws {
        let launch = Launch.Record()
        let ran = Ran()
        launch.later("a") { ran("a") }
        launch.later("b") { ran("b") }
        launch.later("c") { ran("c") }
        launch.mark("window")
        try await Task.sleep(for: .milliseconds(200))
        #expect(ran.names.isEmpty, "Waits for the page while the window is up")
        launch.mark("page")
        #expect(ran.names.isEmpty, "Not in the same turn as the page")
        try await waitFor(timeout: Self.patience) { ran.names.count == 3 }
        #expect(ran.names == ["a", "b", "c"])
        #expect(ran.turns[0] < ran.turns[1] && ran.turns[1] < ran.turns[2], "One piece a turn: \(ran.turns)")
    }

    @Test func withNoPageToWaitForTheWorkStartsOnceTheWindowIsUp() async throws {
        let launch = Launch.Record()
        launch.waitsForPage = false
        let ran = Ran()
        launch.later("a") { ran("a") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ran.names.isEmpty)
        launch.mark("window")
        try await waitFor(timeout: Self.patience) { ran.names == ["a"] }
    }

    @Test func aPageThatNeverLoadsHoldsTheWorkOnlyAWhile() async throws {
        let launch = Launch.Record(pageWait: 0.2)
        let ran = Ran()
        launch.later("a") { ran("a") }
        launch.mark("window")
        try await waitFor(timeout: Self.patience) { ran.names == ["a"] }
    }

    @Test func workLeftForLaterOnceTheLaunchIsOverStillRuns() async throws {
        let launch = Launch.Record()
        let ran = Ran()
        launch.mark("page")
        launch.later("a") { ran("a") }
        try await waitFor(timeout: Self.patience) { ran.names == ["a"] }
    }

    @Test func eachStageIsTimedAndGivesBackWhatItMade() {
        let launch = Launch.Record()
        let made = launch.stage("browser") { 42 }
        #expect(made == 42)
        #expect(launch.stages.map(\.name) == ["browser"])
        #expect(launch.report.contains("browser "))
    }
}

/// MetricKit's reports of Nerda hanging, kept beside its crashes.
@MainActor
struct HangReportTests {
    private static let tree = Data("""
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "Nerda", "binaryUUID": "35A38826", "offsetIntoBinaryTextSegment": 4096, "subFrames": [
              {"binaryName": "AppKit", "binaryUUID": "A", "offsetIntoBinaryTextSegment": 255}]}]}]}
        """.utf8)

    @Test func aHangSaysHowLongAndWhereTheMainThreadWas() {
        let hang = Feedback.describeHang(seconds: 2.46, build: "31", os: "macOS 27.2", tree: Self.tree)
        #expect(hang.contains("2.5 s"))
        #expect(hang.contains("build 31"))
        #expect(hang.contains("0   Nerda   0x1000"))
        #expect(hang.contains("Nerda binary 35A38826"))
    }

    @Test func theLatestHangsAreKeptAndOldOnesGo() {
        var kept: [String] = []
        for index in 1...5 { kept = Feedback.keeping(["hang \(index)"], in: kept) }
        #expect(kept == ["hang 5", "hang 4", "hang 3"])
        // MetricKit hands over the same report again: kept once.
        #expect(Feedback.keeping(["hang 5"], in: kept) == kept)
    }

    @Test func diagnosticsCarryTheLaunchesAndHangsWithinTheLimit() {
        let launch = "Launches\nmain 80 · page 900"
        let hangs = (1...3).map { "Hang \($0) s\n```\n" + String(repeating: "0   Nerda   0x1000\n", count: 120) + "```" }
        let text = Feedback.diagnostics(tabs: "", stalls: nil, launch: launch, hangs: hangs)
        #expect(text.hasPrefix(launch))
        #expect(text.contains("Hang 1 s"))
        #expect(text.utf8.count <= Feedback.diagnosticsLimit)
        // Cut between lines, never inside a block left open.
        #expect(text.components(separatedBy: "```").count % 2 == 1)
    }
}
