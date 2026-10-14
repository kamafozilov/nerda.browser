import Foundation
import Testing
import WebKit
@testable import Nerda

/// A download's thousands of progress reports reach the main thread only as
/// often as its bar moves: every half percent, and at the end.
@Test func downloadProgressMovesEveryHalfPercent() {
    func reports(total: Int64, size: Int64) -> [Int64] {
        var drawn: (received: Int64, total: Int64) = (0, -1)
        var sent: [Int64] = []
        for received in stride(from: Int64(64 * 1024), through: size, by: 64 * 1024)
        where Download.moves(received: received, total: total, from: drawn) {
            drawn = (received, total)
            sent.append(received)
        }
        return sent
    }
    let size: Int64 = 1_024 * 1_024 * 1_024
    let known = reports(total: size, size: size)
    #expect((16_384, 201) == (size / (64 * 1024), known.count))
    #expect(known.last == size)
    // Size unknown: every 256 KB.
    #expect(reports(total: -1, size: size).count == 4_096)
}

/// A PDF's own download button hands the file over whole: it is saved in
/// the downloads folder, under a name not taken, and listed as done.
@MainActor
@Test func aPDFsDownloadButtonSavesIt() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    FileManager.default.createFile(atPath: folder.appending(path: "paper.pdf").path, contents: nil)
    let browser = Browser()
    browser.downloadFolder = folder

    browser.saveData(WKWebView(), data: Data("%PDF".utf8), suggestedFilename: "../paper.pdf", mimeType: "application/pdf", originatingURL: nil)
    while browser.downloads.first?.state != .finished { try await Task.sleep(for: .milliseconds(10)) }
    let item = try #require(browser.downloads.first)
    #expect(item.file == folder.appending(path: "paper (1).pdf"))
    #expect(try Data(contentsOf: folder.appending(path: "paper (1).pdf")) == Data("%PDF".utf8))
    #expect(item.fraction == 1)
}
