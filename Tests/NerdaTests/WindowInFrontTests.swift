import AppKit
import Foundation
import Testing
@testable import Nerda

/// Which window is in front decides where a video goes: the owner leaves a
/// window's tab as another of Nerda's windows comes forward, or as it goes
/// into the Dock, and comes back to it as it comes forward again. Driven
/// here by the window notices Nerda hears (each window's `AppDelegate`),
/// windows never ordered in, blank pages: what is asked of WebKit, not
/// what WebKit does with it (`WindowInFrontFloatingTests` floats for real).
@MainActor
struct WindowInFrontTests {
    /// The windows the owner has: their profile's own, a secondary one (a
    /// tab moved out to it), an incognito one.
    enum Kind: CaseIterable, Sendable { case regular, secondary, incognito }

    /// A browser in a plain window never ordered in, one blank tab on
    /// screen, heard by an `AppDelegate` sharing `inFront`.
    @MainActor final class Window {
        let browser: Browser
        let window: NSWindow
        let delegate: AppDelegate
        let tab: Nerda.Tab

        init(_ kind: Kind, inFront: WindowInFront, settings: UserDefaults) throws {
            browser = switch kind {
            case .regular: Browser(profile: try temporaryProfile())
            case .secondary: Browser(profile: try temporaryProfile(), secondary: true)
            case .incognito: Browser(dataStore: .nonPersistent())
            }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            delegate = AppDelegate(window: window, browser: browser)
            delegate.inFront = inFront
            // Left for another app, the window is covered whole; and no
            // session but its own is saved.
            delegate.cover = { _ in
                let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000), window = CGRect(x: 0, y: 0, width: 100, height: 100)
                return WindowCover(window: window, screens: [screen], above: [window])
            }
            delegate.browsers = { [] }
            tab = browser.open(URL(string: "about:blank")!)
            browser.pictureInPictureSettings = settings
            // Blank, it plays nothing: as though it played a video with sound.
            browser.floatsOnLeaving = { _ in true }
        }

        func becomesMain() { delegate.windowDidBecomeMain(notice(NSWindow.didBecomeMainNotification)) }
        func minimises() { delegate.windowWillMiniaturize(notice(NSWindow.willMiniaturizeNotification)) }
        func appResignsActive() { delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification)) }
        func appHides() { delegate.applicationWillHide(Notification(name: NSApplication.willHideNotification)) }
        func appBecomesActive() { delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification)) }
        func comesOutOfTheDock() { delegate.windowDidDeminiaturize(notice(NSWindow.didDeminiaturizeNotification)) }

        private func notice(_ name: Notification.Name) -> Notification { Notification(name: name, object: window) }
    }

    /// Two windows, `a` then `b`, sharing settings of their own with Auto
    /// Picture-in-Picture `on`, and the same `WindowInFront`.
    @MainActor final class Setup {
        let inFront = WindowInFront()
        let a: Window
        let b: Window
        private let suite = "dev.nerda.tests.window-in-front.\(UUID().uuidString)"

        /// `forApps`: "Also when switching to another app", on with Auto
        /// Picture-in-Picture unless said.
        init(_ a: Kind, _ b: Kind, on: Bool = true, forApps: Bool? = nil) throws {
            let settings = try #require(UserDefaults(suiteName: suite))
            settings.set(on, forKey: PictureInPicture.key)
            settings.set(forApps ?? on, forKey: PictureInPicture.appsKey)
            self.a = try Window(a, inFront: inFront, settings: settings)
            self.b = try Window(b, inFront: inFront, settings: settings)
        }

        func close() { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    /// Another window coming forward in front of the video's: its video is
    /// to float, and the window that came forward asks nothing of its own.
    @Test(arguments: Kind.allCases)
    func anotherWindowComingForwardFloatsTheVideo(kind: Kind) throws {
        let setup = try Setup(kind, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        #expect(!setup.a.tab.wantsFloating)
        setup.b.becomesMain()
        #expect(setup.a.tab.wantsFloating)
        #expect(setup.a.tab.floatingAsked?.floats == true)
        #expect(!setup.b.tab.wantsFloating)
        #expect(setup.b.browser.floatingAsks == 0)
    }

    /// The video's window coming forward again: its video is to be in its
    /// page, and the window that goes behind it is left in its turn.
    @Test(arguments: Kind.allCases)
    func theVideosWindowComingForwardAgainLandsIt(kind: Kind) throws {
        let setup = try Setup(kind, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.b.becomesMain()
        setup.a.becomesMain()
        #expect(!setup.a.tab.wantsFloating)
        #expect(setup.b.tab.wantsFloating)
    }

    /// The same window becoming the main one again, as when the owner goes
    /// to another app and back: no window was left for another.
    @Test func theSameWindowAgainLeavesNothing() throws {
        let setup = try Setup(.regular, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.a.becomesMain()
        #expect(!setup.a.tab.wantsFloating)
        #expect(setup.a.browser.floatingAsks == 0)
    }

    /// Minimising the video's window: its video is to float at once, and the
    /// window that becomes the main one after it leaves nothing more.
    @Test(arguments: Kind.allCases)
    func minimisingTheWindowFloatsTheVideo(kind: Kind) throws {
        let setup = try Setup(kind, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.a.minimises()
        #expect(setup.a.tab.wantsFloating)
        let asks = setup.a.browser.floatingAsks
        #expect(asks == 1)
        setup.b.becomesMain()
        #expect(setup.a.browser.floatingAsks == asks, "Asked again as the next window came forward")
        #expect(setup.b.browser.floatingAsks == 0)
    }

    /// Taking the window out of the Dock lands its video, however many of
    /// the notices that follow say it is in front.
    @Test(arguments: Kind.allCases)
    func takingTheWindowOutOfTheDockLandsIt(kind: Kind) throws {
        let setup = try Setup(kind, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.a.minimises()
        setup.a.comesOutOfTheDock()
        #expect(!setup.a.tab.wantsFloating)
        setup.a.becomesMain()
        #expect(!setup.a.tab.wantsFloating)
    }

    /// Another tab come to in the video's window while it was behind (a link
    /// opened from another app): coming back to the window lands nothing,
    /// the video's tab not being on screen.
    @Test func comingBackToAnotherTabOfTheWindowKeepsTheVideoFloating() throws {
        let setup = try Setup(.regular, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.b.becomesMain()
        _ = setup.a.browser.open(URL(string: "about:blank")!)
        setup.a.becomesMain()
        #expect(setup.a.tab.wantsFloating)
    }

    /// A window closed while in front is not left as the next comes forward:
    /// its tabs are closed, or kept by its profile (a secondary window).
    @Test func aClosedWindowIsNotLeft() throws {
        let setup = try Setup(.secondary, .regular)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.inFront.closed(setup.a.browser)
        setup.b.becomesMain()
        #expect(setup.a.browser.floatingAsks == 0)
    }

    /// With Auto Picture-in-Picture off, no window coming forward, going
    /// into the Dock or coming out of it asks anything of any video, nor
    /// lands one the owner floated themselves.
    @Test(arguments: Kind.allCases)
    func withAutoPictureInPictureOffNothingIsAsked(kind: Kind) throws {
        let setup = try Setup(kind, .regular, on: false)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.b.becomesMain()
        setup.a.becomesMain()
        setup.a.minimises()
        setup.b.becomesMain()
        // As if floated by the page's own button.
        setup.a.browser.webView(setup.a.tab.webView, hasVideoInPictureInPictureDidChange: true)
        setup.a.comesOutOfTheDock()
        setup.a.becomesMain()
        #expect(setup.a.browser.floatingAsks == 0)
        #expect(setup.b.browser.floatingAsks == 0)
        #expect(setup.a.tab.wantsFloating, "Landed what the owner floated")
    }

    /// A muted tab's video has no sound to keep hearing: left with its
    /// window, it isn't asked to float.
    @Test func aMutedTabsVideoIsNotFloated() throws {
        let setup = try Setup(.regular, .regular)
        defer { setup.close() }
        setup.a.tab.isMuted = true
        setup.a.becomesMain()
        setup.b.becomesMain()
        setup.b.minimises()
        #expect(setup.a.browser.floatingAsks == 0)
    }

    /// Each window with a video of its own: the one in front has its video in
    /// its page, the other's floats, as the owner goes from one to the other.
    @Test func eachWindowsVideoFollowsWhichIsInFront() throws {
        let setup = try Setup(.regular, .incognito)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.b.becomesMain()
        #expect(setup.a.tab.wantsFloating && !setup.b.tab.wantsFloating)
        setup.a.becomesMain()
        #expect(!setup.a.tab.wantsFloating && setup.b.tab.wantsFloating)
        setup.b.becomesMain()
        #expect(setup.a.tab.wantsFloating && !setup.b.tab.wantsFloating)
    }

    /// The video floated as Nerda was left for another app, its window covered, and
    /// the owner comes back through another of its windows: the video stays
    /// floating, in whichever order AppKit says the app is active and the
    /// window is in front.
    @Test(arguments: [false, true])
    func comingBackToNerdaInAnotherWindowKeepsTheVideoFloating(activeFirst: Bool) throws {
        let setup = try Setup(.regular, .incognito)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.a.appResignsActive()
        #expect(setup.a.tab.wantsFloating, "Not floated as Nerda was left")
        if activeFirst { setup.a.appBecomesActive() }
        setup.b.becomesMain()
        if !activeFirst { setup.a.appBecomesActive() }
        #expect(setup.a.tab.wantsFloating)
    }

    /// Coming back to Nerda in the video's own window lands it, once, in
    /// whichever order AppKit says so.
    @Test(arguments: [false, true])
    func comingBackToNerdaInTheVideosWindowLandsIt(activeFirst: Bool) throws {
        let setup = try Setup(.regular, .incognito)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.a.appResignsActive()
        #expect(setup.a.tab.wantsFloating, "Not floated as Nerda was left")
        if activeFirst { setup.a.appBecomesActive() }
        setup.a.becomesMain()
        if !activeFirst { setup.a.appBecomesActive() }
        #expect(!setup.a.tab.wantsFloating)
    }

    /// Hiding Nerda (⌘H): the front window's video floats, with Auto
    /// Picture-in-Picture on, whether or not "Also when switching to another
    /// app" is; asked once, though Nerda is left for another app with it;
    /// and lands as the owner comes back.
    @Test(arguments: [false, true])
    func hidingNerdaFloatsTheFrontWindowsVideoOnce(forApps: Bool) throws {
        let setup = try Setup(.regular, .incognito, forApps: forApps)
        defer { setup.close() }
        setup.b.becomesMain()
        setup.a.becomesMain()
        let asks = setup.a.browser.floatingAsks, behind = setup.b.browser.floatingAsks
        setup.a.appHides()
        setup.a.appResignsActive()
        #expect(setup.a.tab.wantsFloating)
        #expect(setup.a.browser.floatingAsks == asks + 1, "Asked \(setup.a.browser.floatingAsks - asks) times")
        #expect(setup.b.browser.floatingAsks == behind, "Asked again of a window not in front")
        setup.a.appBecomesActive()
        setup.a.becomesMain()
        #expect(!setup.a.tab.wantsFloating)
    }

    /// Hiding Nerda with Auto Picture-in-Picture off floats nothing.
    @Test func hidingNerdaWithAutoPictureInPictureOffFloatsNothing() throws {
        let setup = try Setup(.regular, .incognito, on: false)
        defer { setup.close() }
        setup.a.becomesMain()
        setup.a.appHides()
        setup.a.appResignsActive()
        #expect(setup.a.browser.floatingAsks == 0)
        #expect(!setup.a.tab.wantsFloating)
    }
}

/// Another window coming forward, and the Dock, really floating and landing
/// the video in the media test bed's window, Auto Picture-in-Picture on,
/// each test holding `FloatingLock`. No window is brought forward or goes
/// into the Dock: the bed's window is told so by the notices AppKit posts
/// for it, which reach its `AppDelegate` as they would in the app.
@Suite(.serialized)
@MainActor
struct WindowInFrontFloatingTests {
    /// The bed's window, holding the video, in front, and another window of
    /// `other`'s kind beside it, never ordered in.
    @MainActor final class Setup {
        let floating: FloatingFollowsTests.Setup
        let inFront = WindowInFront()
        let delegate: AppDelegate
        let other: WindowInFrontTests.Window

        init(_ kind: WindowInFrontTests.Kind, other: WindowInFrontTests.Kind = .regular) async throws {
            let browser: Browser = switch kind {
            case .regular: Browser(profile: try temporaryProfile())
            case .secondary: Browser(profile: try temporaryProfile(), secondary: true)
            case .incognito: Browser(dataStore: .nonPersistent())
            }
            LowPowerMode.force(false, for: browser.dataStore)
            floating = try await FloatingFollowsTests.Setup(browser: browser)
            delegate = AppDelegate(window: floating.bed.window, browser: browser)
            delegate.inFront = inFront
            floating.bed.window.delegate = delegate
            self.other = try WindowInFrontTests.Window(other, inFront: inFront, settings: browser.pictureInPictureSettings)
            post(NSWindow.didBecomeMainNotification)
        }

        /// As AppKit tells the bed's window.
        func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: floating.bed.window) }

        func close() {
            // Its closing isn't one of the owner's windows closing.
            floating.bed.window.delegate = nil
            floating.close()
        }
    }

    /// Another window coming forward floats the video; its own window
    /// coming forward again lands it, playing on in its page. The same in a
    /// secondary window and an incognito one.
    @Test(arguments: [WindowInFrontTests.Kind.incognito, .secondary])
    func anotherWindowFloatsTheVideoAndItsOwnLandsIt(kind: WindowInFrontTests.Kind) async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup(kind)
        defer { setup.close() }
        setup.other.becomesMain()
        try await setup.floating.settled(floating: true, "Another window in front")
        setup.post(NSWindow.didBecomeMainNotification)
        try await setup.floating.settled(floating: false, "Its window in front again")
        #expect(setup.floating.words.seen == [true, false])
    }

    /// Going into the Dock floats the video; coming out of it lands it.
    @Test func minimisingFloatsTheVideoAndTheDockLandsIt() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup(.incognito)
        defer { setup.close() }
        setup.post(NSWindow.willMiniaturizeNotification)
        try await setup.floating.settled(floating: true, "Minimised")
        // Out of the Dock, AppKit says so, and that it is the main window.
        setup.post(NSWindow.didDeminiaturizeNotification)
        setup.post(NSWindow.didBecomeMainNotification)
        try await setup.floating.settled(floating: false, "Out of the Dock")
        #expect(setup.floating.words.seen == [true, false])
    }

    /// Hiding Nerda (⌘H) floats the video, with "Also when switching to
    /// another app" on too: leaving for another app with it, its window
    /// hidden, asks nothing more; coming back to Nerda lands it.
    @Test func hidingNerdaFloatsTheVideoOnceAndComingBackLandsIt() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup(.incognito)
        defer { setup.close() }
        let browser = setup.floating.bed.browser
        browser.pictureInPictureSettings.set(true, forKey: PictureInPicture.appsKey)
        setup.delegate.cover = { _ in WindowCover(window: CGRect(x: 0, y: 0, width: 100, height: 100), screens: [], above: [], hidden: true) }
        setup.delegate.browsers = { [] }
        setup.delegate.applicationWillHide(Notification(name: NSApplication.willHideNotification))
        let asks = browser.floatingAsks
        setup.delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        try await setup.floating.settled(floating: true, "Nerda hidden")
        #expect(browser.floatingAsks == asks, "Asked again as Nerda was left")
        setup.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        setup.post(NSWindow.didBecomeMainNotification)
        try await setup.floating.settled(floating: false, "Back in Nerda")
        #expect(setup.floating.words.seen == [true, false])
    }
}
