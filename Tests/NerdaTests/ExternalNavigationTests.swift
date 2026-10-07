import Foundation
import Testing
@testable import Nerda

struct ExternalNavigationTests {
    @Test(arguments: [
        ("https://example.com/page?q=hello#section", true),
        ("HTTP://localhost:8080/page", true),
        ("http://127.0.0.1:3000", true),
        ("https://[::1]:8443/page", true),
        ("https:/missing-host", false),
        ("http:///missing-host", false),
        ("https://", false),
        ("page.html", false),
        ("javascript:alert(1)", false),
        ("data:text/html,hello", false),
        ("mailto:hello@example.com", false),
        ("ftp://example.com/page.html", false),
    ])
    func webLinksNeedHTTPAndAHost(address: String, accepted: Bool) throws {
        let url = try #require(URL(string: address))
        #expect(ExternalNavigation.accepts(url) == accepted)
    }

    @Test(arguments: ["page.html", "page.htm", "saved page.HTML", "page.xhtml", "page.XHTML", "document.pdf", "saved document.PDF"])
    func readableLocalDocumentsAreAccepted(name: String) throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: name)
        try Data("Document".utf8).write(to: file)

        #expect(ExternalNavigation.accepts(file))
        var location = try #require(URLComponents(url: file, resolvingAgainstBaseURL: false))
        location.host = "localhost"
        #expect(ExternalNavigation.accepts(try #require(location.url)))
        location.host = "other-mac.example"
        #expect(!ExternalNavigation.accepts(try #require(location.url)))
    }

    @Test func documentsMustExistAndBeReadableRegularFiles() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "page.html")
        #expect(!ExternalNavigation.accepts(file))
        try Data("Document".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(!ExternalNavigation.accepts(file))

        let directory = folder.appending(path: "folder.html")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(!ExternalNavigation.accepts(directory))
        let unsupported = folder.appending(path: "notes.txt")
        try Data("Notes".utf8).write(to: unsupported)
        #expect(!ExternalNavigation.accepts(unsupported))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
