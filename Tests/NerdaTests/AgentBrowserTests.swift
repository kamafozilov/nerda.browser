import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import Nerda

/// Pages served on this Mac, each request kept, with the cookies it came with.
@MainActor
private final class AgentPageServer {
    let listener: NWListener
    var requests: [String] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    self.requests.append(String(decoding: data ?? Data(), as: UTF8.self))
                    let body = "<title>Account</title><p>Signed in</p>"
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String = "/") async throws -> URL {
        try await waitFor { listener.port != nil && listener.port != .any }
        return URL(string: "http://127.0.0.1:\(try #require(listener.port).rawValue)\(path)")!
    }

    /// The requests for `path`, with their headers.
    func requests(for path: String) -> [String] { requests.filter { $0.hasPrefix("GET \(path) ") } }

    deinit { listener.cancel() }
}

/// A profile of its own, in a folder of its own, so nothing here reaches the
/// owner's history or tabs.
@MainActor
private func testProfile() throws -> Profile {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Profile(name: "Agents", symbol: "person", color: .blue, root: folder)
}

@Suite(.serialized)
@MainActor
struct AgentBrowserTests {
    /// An Agent tab is signed in wherever the owner is: it uses the
    /// profile's own cookies.
    @Test func agentTabsUseTheProfilesSignIns() async throws {
        let server = try AgentPageServer()
        let url = try await server.url("/account")
        // The owner's sign-in, in the profile's store.
        let store = WKWebsiteDataStore.nonPersistent()
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "session", .value: "owner",
            .expires: Date.now.addingTimeInterval(3600),
        ]))
        await store.httpCookieStore.setCookie(cookie)

        let agents = AgentBrowser(dataStore: store)
        defer { agents.close() }
        let tab = agents.open(url)
        try await waitFor { !server.requests(for: "/account").isEmpty }
        #expect(server.requests(for: "/account").first?.contains("Cookie: session=owner") == true)
        try await waitFor { tab.url == url && !tab.webView.isLoading }

        // With no store given, the profile's own (Personal's by default), as its windows use.
        let own = AgentBrowser()
        defer { own.close() }
        #expect(own.browser.profile === Profile.main)
        #expect(own.browser.dataStore === Profile.main.dataStore)
    }

    /// What an agent opens is not the owner's browsing: none of it goes in
    /// the profile's history, and no session file keeps its tabs.
    @Test func agentTabsKeepNoHistoryAndNoSession() async throws {
        let server = try AgentPageServer()
        let profile = try testProfile()
        // A store on disk, as the profile's own is: an incognito one keeps nothing anyway.
        let store = WKWebsiteDataStore.default()

        let agents = AgentBrowser(profile: profile, dataStore: store)
        defer { agents.close() }
        let url = try await server.url("/agent")
        let tab = agents.open(url)
        try await waitFor { tab.url == url && !tab.webView.isLoading && tab.title == "Account" }
        agents.browser.saveSession()

        // The owner's own window of the same profile keeps its visit, as ever.
        let owner = Browser(profile: profile, dataStore: store)
        let mine = try await server.url("/mine")
        let ownerTab = owner.open(mine)
        try await waitFor { profile.history.visits[mine] != nil }
        _ = ownerTab

        #expect(profile.history.visits[url] == nil)
        #expect(agents.browser.sessionFile == nil)
        #expect(!FileManager.default.fileExists(atPath: profile.sessionFile.path))
    }

    /// Agent tabs' pages are in a window of their own, there so they draw
    /// and run as on screen, but off every screen, under every window, never
    /// key, never brought forward, and in no list of windows; back off
    /// screen when the screens change.
    @Test func agentTabsLiveInAWindowOffScreen() async throws {
        _ = NSApplication.shared
        let server = try AgentPageServer()
        let agents = AgentBrowser(dataStore: .nonPersistent())
        defer { agents.close() }
        let window = agents.window
        let offScreen = { NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) } }

        let first = agents.open(try await server.url("/first"))
        let second = agents.open(try await server.url("/second"))
        try await waitFor { first.page?.window === window && second.page?.window === window }
        #expect(window.isVisible)
        #expect(offScreen())
        #expect(first.webView.frame.size == window.contentLayoutRect.size)
        #expect(window.level < .normal)
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(window.isExcludedFromWindowsMenu)
        #expect(window.collectionBehavior.contains(.ignoresCycle))

        // Asked to come forward, as the owner's windows are, it stays where it is.
        window.makeKeyAndOrderFront(nil)
        window.orderFront(nil)
        window.orderFrontRegardless()
        #expect(!window.isKeyWindow && !window.isMainWindow)
        #expect(NSApp.keyWindow !== window)
        #expect(offScreen())

        // Moved onto a screen, it goes back off when the screens change.
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await waitFor { offScreen() }

        // Not one of the owner's windows: links, Move to Window and saving at quit pass it by.
        let owner = Browser(dataStore: agents.browser.dataStore)
        owner.add(Nerda.Tab())
        #expect(!Windows.browsers.contains { $0 === agents.browser })
        #expect(Windows.lastUsed?.browser !== agents.browser)
        #expect(!Windows.others(of: owner).contains { $0 === agents.browser })

        // A closed tab's page leaves the window; the last one leaves none in its place.
        agents.close(second.id)
        try await waitFor { second.page?.window == nil }
        agents.close(first.id)
        #expect(agents.browser.tabs.isEmpty)
        try await waitFor { first.page?.window == nil }
    }

    /// The owner goes on as they were while an agent opens tabs: the same
    /// windows in the same order, the same tabs, the same one on screen, the
    /// keyboard where it was.
    @Test func openingAgentTabsLeavesTheOwnerAlone() async throws {
        _ = NSApplication.shared
        let server = try AgentPageServer()
        // Incognito, so links other tests open from other apps never come to
        // this window (`Windows.lastUsed` passes over incognito ones).
        let owner = Browser(dataStore: .nonPersistent())
        let ownerWindow = BrowserWindow(browser: owner)
        ownerWindow.orderBack(nil)
        defer { ownerWindow.close() }
        let mine = owner.open(try await server.url("/mine"))
        try await waitFor { !server.requests(for: "/mine").isEmpty }
        let tabs = owner.tabs.map(\.id), selected = owner.selectedID
        let windows = NSApp.orderedWindows.filter { $0 is BrowserWindow }
        let key = NSApp.keyWindow, main = NSApp.mainWindow, active = NSApp.isActive
        let responder = ownerWindow.firstResponder

        let agents = AgentBrowser(dataStore: owner.dataStore)
        defer { agents.close() }
        let opened = try await ["/one", "/two", "/three"].asyncMap { agents.open(try await server.url($0)) }
        try await waitFor { opened.allSatisfy { $0.page?.window === agents.window && !$0.webView.isLoading } }

        #expect(owner.tabs.map(\.id) == tabs)
        #expect(owner.selectedID == selected && owner.selected === mine)
        #expect(NSApp.orderedWindows.filter { $0 is BrowserWindow } == windows)
        #expect(NSApp.keyWindow === key && NSApp.mainWindow === main && NSApp.isActive == active)
        #expect(ownerWindow.firstResponder === responder)
        // Under the owner's window, not over it.
        #expect(agents.window.orderedIndex > ownerWindow.orderedIndex)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
