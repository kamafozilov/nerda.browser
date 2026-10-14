import Foundation
import Testing
import WebKit
@testable import Nerda

private let page = URL(string: "https://example.com/")!

/// Profiles kept in a folder of their own, gone at the end of the test.
@MainActor
private func profiles(in root: URL) -> Profiles {
    Profiles(file: root.appending(path: "profiles.json"), root: root,
             main: Profile(id: Profile.mainID, name: "Personal", symbol: "person", color: .blue, root: root))
}

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
}

/// Personal keeps what Nerda kept before there were profiles, where it was:
/// nothing moves for someone who never makes another.
@MainActor
@Test func personalKeepsItsDataWhereItWas() {
    let main = Profile.main
    #expect(main.isMain)
    #expect(main.folder == Edition.folder)
    #expect(main.sessionFile == Session.file)
    #expect(main.history === History.shared && History.file == main.folder.appending(path: "history.json"))
    #expect(main.bookmarks === Bookmarks.shared && Bookmarks.file == main.folder.appending(path: "bookmarks.json"))
    #expect(main.siteSettings === SiteSettings.shared)
    #expect(main.vault === Vault.shared)
    #expect(main.passwordsService == "\(Edition.name) Passwords")
    #expect(main.dataStore === WKWebsiteDataStore.default())
    #expect(Browser().profile === main)
    // No file until one is made: Personal alone.
    let root = folder()
    #expect(profiles(in: root).all.map(\.id) == [Profile.mainID])
    #expect(!FileManager.default.fileExists(atPath: root.path()))
}

/// Each profile's history, bookmarks, site settings, open tabs and website
/// data are its own, in its own folder and data store.
@MainActor
@Test func profilesKeepTheirBrowsingApart() async throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let all = profiles(in: root)
    let work = all.add(name: "Work", symbol: "briefcase", color: .orange)
    let home = all.add(name: "Home", symbol: "house", color: .green)
    #expect(work.folder == root.appending(path: "Profiles/\(work.id.uuidString)"))

    let atWork = Browser(profile: work), atHome = Browser(profile: home)
    #expect(atWork.history === work.history && atWork.bookmarks === work.bookmarks && atWork.siteSettings === work.siteSettings)

    work.history.visit(page, title: "Example")
    work.history.save()
    #expect(home.history.visits[page] == nil)
    #expect(FileManager.default.fileExists(atPath: work.folder.appending(path: "history.json").path()))
    #expect(!FileManager.default.fileExists(atPath: home.folder.appending(path: "history.json").path()))

    work.bookmarks.add(Bookmarks.Item(title: "Example", url: page))
    Bookmarks.writer.sync {}
    #expect(home.bookmarks.items.isEmpty)
    #expect(FileManager.default.fileExists(atPath: work.folder.appending(path: "bookmarks.json").path()))

    var options = SiteSettings.Options()
    options.allowsPopups = true
    atWork.changeSiteOptions(options, for: page)
    #expect(atHome.siteSettings.options(for: page) == SiteSettings.Options())
    #expect(SiteSettings(defaults: nil, file: work.folder.appending(path: "site-settings.json")).options(for: page) == options)

    atWork.restore(from: work.sessionFile, loadingPins: false)
    atWork.add([Nerda.Tab(restoring: Session.Tab(url: page, title: "Example", state: nil, zoom: 1, pinned: nil, home: nil))])
    atWork.saveSession()
    #expect(Session.read(from: work.sessionFile)?.tabs.map(\.url) == [page])
    #expect(Session.read(from: home.sessionFile) == nil)

    #expect(work.dataStore.identifier == work.id && home.dataStore.identifier == home.id)
    #expect(work.dataStore !== home.dataStore && atWork.dataStore === work.dataStore)
    #expect(Profile.main.dataStore.identifier == nil)

    // Read back as they were left, a window left open to open again at launch.
    work.open = true
    all.save()
    let read = profiles(in: root).all
    #expect(read.map(\.name) == ["Personal", "Work", "Home"])
    #expect(read.map(\.open) == [false, true, false])
    #expect(read[1].color == .orange && read[1].symbol == "briefcase")
    atWork.closeAll()
    await all.remove(work)
    await all.remove(home)
}

/// Deleting a profile takes its files and website data with it; Personal
/// can't be deleted.
@MainActor
@Test func deletingAProfileTakesItsDataAlong() async throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let all = profiles(in: root)
    let work = all.add(name: "Work", symbol: "briefcase", color: .orange)
    work.history.visit(page, title: "Example")
    work.history.save()
    let cookie = HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "signed", .value: "in",
                                         .expires: Date.now.addingTimeInterval(3600)])!
    await work.dataStore.httpCookieStore.setCookie(cookie)
    #expect(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(work.id))

    // Left for the next launch until WebKit has removed it, should Nerda quit meanwhile.
    let removing = Task { await all.remove(work) }
    // WebKit is first asked half a second on.
    for _ in 0..<20 where !Profiles.storesLeft.contains(work.id) { try await Task.sleep(for: .milliseconds(20)) }
    #expect(Profiles.storesLeft.contains(work.id))
    await removing.value
    #expect(!FileManager.default.fileExists(atPath: work.folder.path()))
    #expect(await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(work.id))
    #expect(!Profiles.storesLeft.contains(work.id))
    #expect(profiles(in: root).all.map(\.id) == [Profile.mainID])
    // A late write, as an import finishing, doesn't bring the folder back.
    work.bookmarks.add(Bookmarks.Item(title: "Example", url: page))
    var options = SiteSettings.Options()
    options.allowsPopups = true
    work.siteSettings.set(options, for: page)
    #expect(await !work.vault.save([(Account(host: "example.com", user: "me"), "secret")]))
    Bookmarks.writer.sync {}
    #expect(!FileManager.default.fileExists(atPath: work.folder.path()))

    await all.remove(all.all[0])
    #expect(all.all.count == 1)
}

/// A profile's site settings that can't be read (from a newer Nerda, say)
/// are set aside before anything is written over them.
@MainActor
@Test func unreadableSiteSettingsAreSetAside() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "site-settings.json")
    let unreadable = Data(#"{"sites": "from a newer version"}"#.utf8)
    try unreadable.write(to: file)
    let settings = SiteSettings(defaults: nil, file: file)
    #expect(settings.options(for: page) == SiteSettings.Options())
    var options = SiteSettings.Options()
    options.allowsPopups = true
    settings.set(options, for: page)
    #expect(try Data(contentsOf: root.appending(path: "site-settings-unreadable.json")) == unreadable)
}
