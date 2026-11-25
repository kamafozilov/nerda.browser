import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents upload and download files without a panel (spec #119, ticket
/// #140): `upload` answers the page's file panel with the files staged for
/// it, and a download from an Agent tab goes straight to its session's
/// folder under Downloads, named in the answer.
@MainActor
struct AgentFilesTests {
    /// The file control's own panel is answered with the files: the page
    /// gets them, whole, and no panel ever shows.
    @Test func uploadAttachesTheFilesWithoutAPanel() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/upload", Self.uploadPage)
        let report = try file("report.txt", "Quarterly numbers", in: harness)
        let photo = try file("photo.jpg", "not really a photo", in: harness)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let control = try #require(try await ref(of: "Attachment", agent), "no file control")

        let answer = try await agent.call("upload", ["tab": "t1", "ref": .string(control),
                                                     "paths": [.string(report.path), .string(photo.path)]])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("report.txt") && answer.text.contains("photo.jpg"), "\(answer.text)")
        #expect(try await chosen(harness) == ["report.txt: Quarterly numbers", "photo.jpg: not really a photo"])
        #expect(try await opened(harness) == 1, "the page's own click on the control opens its panel once")
        #expect(!answer.text.contains("by script"), "\(answer.text)")
        #expect(!panelShown(harness))
    }

    /// The usual styled control: a button whose script presses a hidden
    /// file input. The panel that press opens takes the files.
    @Test func uploadThroughAButtonThatOpensAHiddenControl() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/styled", """
            <title>Styled</title>
            <button onclick="file.click()">Add attachment</button>
            <input type=file id=file style="display: none">
            <script>
            window.chosen = null;
            file.addEventListener('change', async () => {
                chosen = await Promise.all([...file.files].map(async (f) => f.name + ': ' + await f.text()));
            });
            </script>
            """)
        let report = try file("report.txt", "Quarterly numbers", in: harness)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let button = try #require(try await ref(of: "Add attachment", agent), "no button")

        let answer = try await agent.call("upload", ["tab": "t1", "ref": .string(button), "paths": [.string(report.path)]])

        #expect(!answer.isError, "\(answer.text)")
        #expect(!answer.text.contains("by script"), "\(answer.text)")
        #expect(try await chosen(harness) == ["report.txt: Quarterly numbers"])
        #expect(!panelShown(harness))
    }

    /// A control whose page keeps its panel shut gets the files by script
    /// instead, and the answer says so.
    @Test func aControlThatOpensNoPanelGetsTheFilesByScript() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/shut", Self.uploadPage.replacing(
            "file.addEventListener('click', () => opened++);",
            with: "file.addEventListener('click', (event) => { opened++; event.preventDefault(); });"
        ))
        let report = try file("report.txt", "Quarterly numbers", in: harness)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let control = try #require(try await ref(of: "Attachment", agent), "no file control")

        let answer = try await agent.call("upload", ["tab": "t1", "ref": .string(control), "paths": [.string(report.path)]])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("by script"), "\(answer.text)")
        #expect(try await chosen(harness) == ["report.txt: Quarterly numbers"])
        #expect(!panelShown(harness))
    }

    /// A file control clicked rather than given files opens no panel
    /// either: the answer says the page asked for files, to give with upload.
    @Test func aFileControlClickedWithoutFilesShowsNoPanel() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/upload", Self.uploadPage)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let control = try #require(try await ref(of: "Attachment", agent), "no file control")

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(control)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("asked for files"), "\(answer.text)")
        #expect(!panelShown(harness))
    }

    /// Files over 100 MB in all are refused before anything is pressed;
    /// so is a path with no file.
    @Test func filesOverTheLimitAreRefused() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/upload", Self.uploadPage)
        let large = try file("large.bin", "", in: harness)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 100 * 1024 * 1024 + 1) // sparse: takes no room
        try handle.close()
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let control = try #require(try await ref(of: "Attachment", agent), "no file control")

        let refused = try await agent.call("upload", ["tab": "t1", "ref": .string(control), "paths": [.string(large.path)]])
        let missing = try await agent.call("upload", ["tab": "t1", "ref": .string(control),
                                                      "paths": [.string(harness.folder.appending(path: "none.txt").path)]])

        #expect(refused.isError)
        #expect(refused.text.contains("100 MB"), "\(refused.text)")
        #expect(missing.isError)
        #expect(missing.text.contains("no file"), "\(missing.text)")
        #expect(try await opened(harness) == 0, "nothing was pressed")
    }

    /// A download from an Agent tab goes straight to a folder of its
    /// session's under Downloads, without a panel, and the answer to the
    /// click that started it names the file. Another session's downloads go
    /// to a folder of their own.
    @Test func aDownloadLandsInTheSessionsFolderAndIsReported() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        try await harness.pages.serve("/report.txt", "Quarterly numbers")
        let url = try await harness.pages.serve("/files", """
            <title>Files</title>
            <a href="/report.txt" download="report.txt">Quarterly report</a>
            """)
        let agent = try await harness.agent()
        let other = try await harness.agent(session: "session-2")
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        _ = try await other.call("open", ["url": AgentJSON(url)])
        let link = try #require(try await ref(of: "Quarterly report", agent), "no link")
        let otherLink = try #require(try await ref(of: "Quarterly report", other, tab: "t2"), "no link")

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(link)])
        let otherAnswer = try await other.call("click", ["tab": "t2", "ref": .string(otherLink)])

        #expect(!answer.isError, "\(answer.text)")
        let file = try #require(downloaded(in: answer.text), "\(answer.text)")
        let otherFile = try #require(downloaded(in: otherAnswer.text), "\(otherAnswer.text)")
        #expect(file.lastPathComponent == "report.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "Quarterly numbers")
        let folder = file.deletingLastPathComponent()
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == harness.downloads.standardizedFileURL.path,
                "a folder of the session's right under Downloads: \(file.path)")
        #expect(otherFile.deletingLastPathComponent() != folder, "each session has a folder of its own")
        #expect(!panelShown(harness))
    }

    // MARK: - Helpers

    /// The file an answer says was downloaded: the path after "downloaded … to".
    private func downloaded(in answer: String) -> URL? {
        answer.firstMatch(of: #/notice: downloaded .* to (/.+)$/#.anchorsMatchLineEndings())
            .map { URL(fileURLWithPath: String($0.output.1)) }
    }

    /// A file control that writes down each file it is given, with what is in it.
    static let uploadPage = """
        <title>Upload</title>
        <label>Attachment <input type=file id=file multiple></label>
        <script>
        window.chosen = null; window.opened = 0;
        file.addEventListener('click', () => opened++);
        file.addEventListener('change', async () => {
            chosen = await Promise.all([...file.files].map(async (f) => f.name + ': ' + await f.text()));
        });
        </script>
        """

    /// A file of the test's own, written with `text`.
    private func file(_ name: String, _ text: String, in harness: AgentHarness) throws -> URL {
        let folder = harness.folder.appending(path: "Files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// What the page's file control was given, once it has been.
    private func chosen(_ harness: AgentHarness) async throws -> [String]? {
        let page = try #require(harness.agents?.tabs.first?.page)
        var files: [String]?
        try await waitFor(timeout: .seconds(5)) {
            files = try? await page.callAsyncJavaScript("return window.chosen", contentWorld: .page) as? [String]
            return files != nil
        }
        return files
    }

    private func opened(_ harness: AgentHarness) async throws -> Int? {
        let page = try #require(harness.agents?.tabs.first?.page)
        return try await page.callAsyncJavaScript("return window.opened", contentWorld: .page) as? Int
    }

    /// Whether a file or save panel, or any sheet, is up anywhere.
    private func panelShown(_ harness: AgentHarness) -> Bool {
        NSApp.windows.contains { ($0 is NSSavePanel) && $0.isVisible } || harness.agents?.window.attachedSheet != nil
    }

    /// The ref of the first outline line naming `element`, from a fresh snapshot.
    private func ref(of element: String, _ agent: AgentTestClient, tab: String = "t1") async throws -> String? {
        let outline = try await agent.call("snapshot", ["tab": .string(tab)]).text
        return outline.split(separator: "\n").first { $0.contains(#""\#(element)""#) }
            .flatMap { $0.firstMatch(of: #/^\s*- ((?:f\d+)?e\d+) /#) }
            .map { String($0.output.1) }
    }
}
