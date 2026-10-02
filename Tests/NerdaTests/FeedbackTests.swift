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
