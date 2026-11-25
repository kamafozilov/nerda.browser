import AppKit
import Foundation
import Network
import SwiftUI
import Testing
@testable import Nerda

/// Serves a short page with some text at any address.
@MainActor
private final class TextServer {
    let listener: NWListener
    nonisolated static let page = "<!doctype html><body><h1>Recorded</h1><p>Some text to paint.</p></body>"

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(TextServer.page.utf8.count)\r\nConnection: close\r\n\r\n" + TextServer.page
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String) async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://127.0.0.1:\(try #require(listener.port).rawValue)\(path)")!
    }
}

/// The record of how long tab operations took (Recorder): what a person
/// does to the browser leaves a timing there. The numbers themselves are
/// not checked, only that they are kept.
@MainActor
struct RecorderTests {
    /// A browser with a record of its own, so other tests' tabs don't mix in.
    private func recordedBrowser() -> (Browser, Recorder) {
        let browser = Browser(dataStore: .nonPersistent())
        let recorder = Recorder()
        browser.recorder = recorder
        return (browser, recorder)
    }

    private func kinds(_ recorder: Recorder) -> [Recorder.Kind] { recorder.timings().map(\.kind) }

    /// A tab operation is timed once the main loop next goes to sleep. With
    /// the whole suite running, hundreds of tests keep it busy for seconds
    /// on end, so this waits longer than `waitFor` does.
    private func settled(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        try await waitFor(timeout: .seconds(30), sourceLocation: sourceLocation, condition)
    }

    @Test func openingATabIsTimed() async throws {
        let (browser, recorder) = recordedBrowser()
        browser.newTab()
        try await settled { kinds(recorder).contains(.tabOpen) }
    }

    @Test func switchingTabsIsTimed() async throws {
        let (browser, recorder) = recordedBrowser()
        browser.newTab()
        browser.newTab()
        let first = try #require(browser.tabs.first { $0.id != browser.selectedID })
        try await settled { kinds(recorder).contains(.tabOpen) }
        browser.select(first.id)
        try await settled { kinds(recorder).contains(.tabSwitch) }
    }

    @Test func closingATabIsTimed() async throws {
        let (browser, recorder) = recordedBrowser()
        browser.newTab()
        browser.newTab()
        try await settled { kinds(recorder).contains(.tabOpen) }
        browser.closeSelectedTab()
        try await settled { kinds(recorder).contains(.tabClose) }
        // The tab put on screen in its place is the close's, not a switch of its own.
        #expect(!kinds(recorder).contains(.tabSwitch))
    }

    /// ⌘W on a pinned tab puts its page down rather than closing it: a close all the same.
    @Test func closingAPinnedTabIsTimed() async throws {
        let (browser, recorder) = recordedBrowser()
        browser.newTab()
        browser.newTab()
        let pinned = try #require(browser.selected)
        browser.setPinned(true, pinned.id)
        try await settled { kinds(recorder).contains(.tabOpen) }
        browser.closeSelectedTab()
        try await settled { kinds(recorder).contains(.tabClose) }
    }

    /// However long Nerda runs, the record holds only its last five minutes,
    /// and only so many of them.
    @Test func theRecordStaysBounded() {
        var now: TimeInterval = 1000
        let recorder = Recorder(clock: { now })
        for _ in 0..<10_000 {
            recorder.record(.firstPaint, seconds: 0.05)
            recorder.hitch(0.2)
            now += 0.01
        }
        #expect(!recorder.timings().isEmpty && recorder.timings().count < 1000)
        #expect(!recorder.hitches().isEmpty && recorder.hitches().count < 1000)
        now += 301
        #expect(recorder.timings().isEmpty)
        #expect(recorder.hitches().isEmpty)
    }

    /// Only a stop of 100 ms or more is a hitch.
    @Test func shortStopsAreNotHitches() {
        let recorder = Recorder()
        recorder.hitch(0.05)
        #expect(recorder.hitches().isEmpty)
        recorder.hitch(0.15)
        #expect(recorder.hitches().count == 1)
    }

    /// NERDA_RECORDER=0 leaves the record empty for the run.
    @Test func theSwitchTurnsTheRecordOff() async throws {
        let (browser, recorder) = recordedBrowser()
        do {
            Speedups.overrides["RECORDER"] = false
            defer { Speedups.overrides["RECORDER"] = nil }
            browser.newTab()
            recorder.record(.firstPaint, seconds: 0.1)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.timings().isEmpty)
    }

    /// A browser in a window kept behind the others, where its pages paint.
    private func windowedBrowser() -> (Browser, Recorder, NSWindow) {
        let (browser, recorder) = recordedBrowser()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
        window.orderBack(nil)
        return (browser, recorder, window)
    }

    @Test func aPagesFirstPaintIsTimed() async throws {
        let server = try TextServer()
        let (browser, recorder, window) = windowedBrowser()
        defer { window.close() }
        browser.open(try await server.url("/first"))
        try await waitFor { kinds(recorder).contains(.firstPaint) }
    }

    @Test func backAndForwardAreTimed() async throws {
        let server = try TextServer()
        let (browser, recorder, window) = windowedBrowser()
        defer { window.close() }
        let tab = browser.open(try await server.url("/one"))
        try await waitFor { tab.page?.isLoading == false && tab.page?.url != nil }
        tab.go(to: try await server.url("/two"))
        try await waitFor { tab.page?.isLoading == false && tab.page?.url?.path == "/two" }
        tab.webView.goBack()
        try await waitFor { kinds(recorder).filter { $0 == .backForward }.count == 1 }
        tab.webView.goForward()
        try await waitFor { kinds(recorder).filter { $0 == .backForward }.count == 2 }
    }

    /// A feedback report carries what was recorded, by kind, and stays short
    /// enough to travel in the address GitHub opens, however much there is.
    @Test func aReportCarriesTheRecordAndStaysShort() {
        var now: TimeInterval = 1000
        let recorder = Recorder(clock: { now })
        #expect(recorder.report.isEmpty)
        recorder.record(.tabSwitch, seconds: 0.012)
        recorder.hitch(0.25)
        #expect(recorder.report.contains("tab switch"))
        #expect(recorder.report.contains("250 ms"))
        for _ in 0..<5000 {
            for kind in Recorder.Kind.allCases { recorder.record(kind, seconds: 0.123) }
            recorder.hitch(1.5)
            now += 0.05
        }
        #expect(recorder.report.utf8.count <= 1024)
    }

    @Test func feedbackCarriesTheRecord() async throws {
        let browser = Browser(dataStore: .nonPersistent())
        browser.newTab()
        browser.newTab()
        try await settled { Recorder.shared.timings().contains { $0.kind == .tabOpen } }
        #expect(Feedback.diagnostics.contains("tab open"))
        #expect(Feedback.diagnostics.utf8.count <= Feedback.diagnosticsLimit)
    }
}
