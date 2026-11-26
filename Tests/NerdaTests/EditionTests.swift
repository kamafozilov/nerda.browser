import Foundation
import Testing
@testable import Nerda

/// The tests keep what Nerda keeps (tabs, history, icons, accounts, the
/// agents' socket…) in a folder of their own run, never in an edition's:
/// a test opening tabs once replaced the owner's Nerda Dev tabs with its own.
@MainActor @Test func theTestsKeepTheirDataInAFolderOfTheirOwn() {
    #expect(Edition.testing)
    let folder = Edition.folder.standardizedFileURL.path + "/"
    let support = URL.applicationSupportDirectory.standardizedFileURL.path
    for edition in ["Nerda", "Nerda Dev", "Nerda Test"] {
        #expect(!folder.hasPrefix("\(support)/\(edition)/"))
    }
    #expect(folder.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
    // Every file the app keeps is in it.
    for file in [Session.file, History.file, Bookmarks.file, Favicons.folder, Backdrop.folder, FilterList.folder,
                 Extensions.folder, Watchdog.file, AgentWire.socket, Downloads.folder] {
        #expect(file.standardizedFileURL.path.hasPrefix(folder))
    }
    // And the keychain items named after it (`Profile.passwordsService`) aren't an edition's.
    #expect(!["Nerda", "Nerda Dev", "Nerda Test"].contains(Edition.name))
    // The agents' socket path fits a Unix socket address (104 bytes).
    #expect(AgentWire.socket.path.utf8.count < 104)
}

/// A window of Personal's, as the app opens it, keeps its tabs in the
/// tests' folder: where a test's tabs once replaced the owner's.
@MainActor @Test func aWindowsTabsAreKeptInTheTestsFolder() throws {
    let file = Edition.folder.appending(path: "session.json")
    let browser = Browser()
    browser.restore(from: browser.profile.sessionFile, loadingPins: false)
    defer {
        browser.closeAll()
        try? FileManager.default.removeItem(at: file)
    }
    let page = URL(string: "http://127.0.0.1:1/kept-in-the-tests-folder")!
    _ = browser.open(page, inBackground: true)
    browser.saveSession()
    #expect(try #require(Session.read(from: file)).tabs.map(\.url).contains(page))
}
