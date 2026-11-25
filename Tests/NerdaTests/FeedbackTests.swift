import Foundation
import Testing
@testable import Nerda

/// A crash's calls, from MetricKit's tree, innermost first, as symbolicate.sh reads them.
@Test func crashReportListsTheCrashedThreadsCalls() {
    let tree = Data("""
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [{"binaryName": "libsystem_kernel.dylib", "binaryUUID": "K", "offsetIntoBinaryTextSegment": 1}]},
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "Nerda", "binaryUUID": "35A38826", "offsetIntoBinaryTextSegment": 4096, "subFrames": [
              {"binaryName": "AppKit", "binaryUUID": "A", "offsetIntoBinaryTextSegment": 255}]}]}]}
        """.utf8)
    let calls = Feedback.calls(in: tree)
    #expect(calls == [.init(binary: "Nerda", uuid: "35A38826", offset: 4096), .init(binary: "AppKit", uuid: "A", offset: 255)])
    #expect(Feedback.lines(calls) == ["0   Nerda   0x1000", "1   AppKit  0xff"])
    #expect(Feedback.calls(in: Data("{}".utf8)).isEmpty)
}

/// What is written goes to GitHub as it is, line breaks and all.
@Test func issueAddressCarriesTheTextAsWritten() throws {
    let url = try #require(Feedback.issue(template: "problem.md", title: "A & B", body: "1+1=2\n#3"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    #expect(url.host() == "github.com")
    #expect(items?.map(\.value) == ["problem.md", "A & B", "1+1=2\n#3"])
}

@Test func diagnosticsShareOneLimitMostUsefulFirst() throws {
    let tabs = "Timings in the last 5 minutes, newest first, in ms:\ntab open: 40 38"
    let stalls = String(repeating: "2026-11-25T10:00:00Z  stall 1.2 s\n0   Nerda   0x1000\n", count: 40)
    let launch = "Launches\nmain 80 · page 900"
    let hangs = (1...3).map { "Hang \($0) s\n```\n" + String(repeating: "0   Nerda   0x1000\n", count: 120) + "```" }
    let text = Feedback.diagnostics(tabs: tabs, stalls: String(stalls.suffix(Feedback.stallsLimit)), launch: launch, hangs: hangs)
    #expect(text.hasPrefix(tabs))
    let stallsAt = try #require(text.range(of: "Stalls:\n```"))
    let launchAt = try #require(text.range(of: launch))
    #expect(stallsAt.lowerBound < launchAt.lowerBound)
    #expect(text.utf8.count <= Feedback.diagnosticsLimit)
    // Cut between lines, never inside a block left open.
    #expect(text.components(separatedBy: "```").count % 2 == 1)
    // Nothing recorded, nothing added.
    #expect(Feedback.diagnostics(tabs: "", stalls: nil, launch: "", hangs: []).isEmpty)
}
