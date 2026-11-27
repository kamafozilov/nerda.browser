import AppKit
import Foundation
import Testing
@testable import Nerda

/// Leaving Nerda for another app with "Also when switching to another app"
/// on: the video floats once its window is hidden or at least half covered,
/// and lands as the owner comes back. Nerda is never really left here: the
/// app delegate of the media test bed's own window hears Nerda resign and
/// become active as AppKit would tell it, and how much of the window other
/// windows cover is the test's to say (the bed's window is behind the
/// owner's, really covered by them). The video really floats, each test
/// holding `FloatingLock`.
@Suite(.serialized)
@MainActor
struct OtherAppTests {
    typealias Setup = FloatingFollowsTests.Setup

    /// The bed's window, as the app delegate of the regular window has it,
    /// with a cover of the test's own.
    @MainActor final class Leaving {
        let setup: Setup
        let delegate: AppDelegate
        /// The share of the window covered, as the delegate reads it.
        var covered = 0.0
        /// How many times it was read.
        private(set) var reads = 0

        init(_ setup: Setup, forApps: Bool = true) {
            self.setup = setup
            let browser = setup.bed.browser
            browser.pictureInPictureSettings.set(forApps, forKey: PictureInPicture.appsKey)
            delegate = AppDelegate(window: setup.bed.window, browser: browser)
            // The bed's window in front, as Nerda is left.
            delegate.inFront = WindowInFront()
            delegate.inFront.cameForward(browser)
            delegate.browsers = { [browser] }
            delegate.coverReadEvery = 0.05
            let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            delegate.cover = { [unowned self] _ in
                reads += 1
                let window = CGRect(x: 0, y: 0, width: 100, height: 100)
                return WindowCover(window: window, screens: [screen], above: [CGRect(x: 0, y: 0, width: covered * 100, height: 100)])
            }
        }

        func leaveNerda() { delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification)) }
        func comeBack() { delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification)) }

        /// Waits until the cover has been read `more` times more, nothing
        /// floating.
        func readsOn(_ more: Int = 3) async throws {
            let until = reads + more
            try await waitFor("The cover was read \(reads) times, not \(until)") { reads >= until }
        }
    }

    /// Hidden or half covered as Nerda is left: the video floats, and lands
    /// as the owner comes back.
    @Test(arguments: [0.5, 1])
    func leavingNerdaWithTheWindowCoveredFloatsTheVideo(covered: Double) async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let leaving = Leaving(setup)
        leaving.covered = covered
        leaving.leaveNerda()
        try await setup.settled(floating: true, "Left Nerda, \(covered) covered")
        #expect(leaving.delegate.away == nil)
        leaving.comeBack()
        try await setup.settled(floating: false, "Back in Nerda")
        #expect(setup.words.seen == [true, false])
    }

    /// More than half in view, on another screen say: nothing floats, not
    /// even later, and coming back asks nothing.
    @Test func leavingNerdaWithTheWindowInViewFloatsNothing() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let leaving = Leaving(setup)
        leaving.covered = 0.49
        let asks = setup.bed.browser.floatingAsks
        leaving.leaveNerda()
        try await leaving.readsOn()
        leaving.comeBack()
        #expect(leaving.delegate.away == nil)
        #expect(setup.bed.browser.floatingAsks == asks)
        #expect(!setup.watched.tab.isFloating && setup.watched.tab.floatingAsked == nil)
        #expect(setup.words.seen.isEmpty)
    }

    /// Covered while Nerda is in the background: it floats then. Uncovered
    /// again, it stays floating until the owner is back in Nerda.
    @Test func aWindowCoveredLaterFloatsItsVideoThen() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let leaving = Leaving(setup)
        leaving.covered = 0.2
        leaving.leaveNerda()
        try await leaving.readsOn()
        #expect(setup.words.seen.isEmpty)
        leaving.covered = 0.7
        try await setup.settled(floating: true, "Covered later")
        let asks = setup.bed.browser.floatingAsks
        leaving.covered = 0
        // Floating, the cover is no longer read.
        #expect(leaving.delegate.away?.isWatching == false)
        #expect(setup.watched.tab.isFloating && setup.bed.browser.floatingAsks == asks)
        leaving.comeBack()
        try await setup.settled(floating: false, "Back in Nerda")
        #expect(setup.words.seen == [true, false])
    }

    /// What tells the window's cover changed (here its being hidden or
    /// shown) has it read at once, not on the next round.
    @Test func aChangeToTheWindowsCoverIsReadAtOnce() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let leaving = Leaving(setup)
        leaving.delegate.coverReadEvery = 3600
        leaving.covered = 0
        leaving.leaveNerda()
        leaving.covered = 1
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: setup.bed.window)
        try await setup.settled(floating: true, "Hidden")
        leaving.comeBack()
        try await setup.settled(floating: false, "Back in Nerda")
    }

    /// With the sub-setting off, leaving Nerda floats nothing, however
    /// covered its window: the cover isn't even read.
    @Test func withTheSubSettingOffLeavingNerdaFloatsNothing() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let leaving = Leaving(setup, forApps: false)
        leaving.covered = 1
        let asks = setup.bed.browser.floatingAsks
        leaving.leaveNerda()
        #expect(leaving.delegate.away == nil && leaving.reads == 0)
        leaving.comeBack()
        #expect(setup.bed.browser.floatingAsks == asks && setup.words.seen.isEmpty)
    }

    /// The session is written as Nerda is left: with a video about to float,
    /// on a later turn of the main loop than floating is asked in, and all
    /// of it should Nerda quit straight after; with none, at once as before.
    @Test(arguments: [false, true])
    func theSessionIsWrittenAsNerdaIsLeft(floats: Bool) async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "nerda-other-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "session.json")
        let browser = setup.bed.browser
        browser.sessionFile = file
        let urls = browser.tabs.compactMap(\.url)
        let leaving = Leaving(setup)
        leaving.covered = floats ? 1 : 0
        leaving.leaveNerda()
        Session.writer.sync {}
        if floats {
            #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
            try await waitFor("The session was never written") { Session.read(from: file) != nil }
        }
        #expect(Session.read(from: file)?.tabs.compactMap(\.url) == urls)
        if floats { try await setup.settled(floating: true, "Left Nerda") }
        leaving.comeBack()
        if floats { try await setup.settled(floating: false, "Back in Nerda") }
    }

    /// Quitting straight after leaving, before the main loop turns again:
    /// the session is all there.
    @Test func quittingStraightAfterLeavingLosesNothing() async throws {
        let lock = try await FloatingLock.take()
        defer { lock.release() }
        let setup = try await Setup()
        defer { setup.close() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "nerda-other-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "session.json")
        let browser = setup.bed.browser
        browser.sessionFile = file
        let urls = browser.tabs.compactMap(\.url)
        let leaving = Leaving(setup)
        leaving.covered = 1
        leaving.leaveNerda()
        leaving.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let session = try #require(Session.read(from: file))
        #expect(session.tabs.compactMap(\.url) == urls)
        #expect(session.selected.map { session.tabs[$0].url } == setup.watched.tab.url)
        try await setup.settled(floating: true, "Left Nerda")
        leaving.comeBack()
        try await setup.settled(floating: false, "Back in Nerda")
    }
}
