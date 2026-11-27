import AppKit
import Testing
@testable import Nerda

/// How much of a window other windows cover, worked out from plain
/// rectangles as the window server lists them: no screen needed.
struct WindowCoverTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = CGRect(x: 100, y: 100, width: 400, height: 200)

    @Test func aWindowWithNothingOverItIsInFullView() {
        let cover = WindowCover(window: window, screens: [screen], above: [])
        #expect(cover.covered == 0)
        #expect(!cover.hidesVideo)
    }

    /// Half covered is enough; just under half is not.
    @Test func aWindowHalfCoveredHidesItsVideo() {
        let half = WindowCover(window: window, screens: [screen], above: [CGRect(x: 100, y: 100, width: 200, height: 200)])
        #expect(half.covered == 0.5)
        #expect(half.hidesVideo)
        let under = WindowCover(window: window, screens: [screen], above: [CGRect(x: 100, y: 100, width: 196, height: 200)])
        #expect(under.covered == 0.49)
        #expect(!under.hidesVideo)
    }

    /// Two windows over the same part cover it once.
    @Test func overlappingWindowsAreCountedOnce() {
        let cover = WindowCover(window: window, screens: [screen], above: [
            CGRect(x: 100, y: 100, width: 160, height: 200),
            CGRect(x: 180, y: 100, width: 160, height: 200),
        ])
        #expect(cover.covered == 0.6)
        #expect(cover.hidesVideo)
    }

    /// Only what lies over the window counts, however large the window above.
    @Test func aWindowAboveCountsOnlyWhereItLiesOverTheWindow() {
        let cover = WindowCover(window: window, screens: [screen], above: [CGRect(x: -500, y: 0, width: 700, height: 2000)])
        #expect(cover.covered == 0.25)
        let elsewhere = WindowCover(window: window, screens: [screen], above: [CGRect(x: 600, y: 100, width: 300, height: 300)])
        #expect(elsewhere.covered == 0)
    }

    /// A window part off the edge of the screens: of the part that is on
    /// them, the share other windows cover. The part off screen is no one's.
    @Test func thePartOffTheScreensIsLeftOut() {
        let sticksOut = CGRect(x: 800, y: 100, width: 400, height: 200)
        #expect(WindowCover(window: sticksOut, screens: [screen], above: []).covered == 0)
        let cover = WindowCover(window: sticksOut, screens: [screen], above: [CGRect(x: 800, y: 100, width: 100, height: 200)])
        #expect(cover.covered == 0.5)
    }

    /// Across two screens, the window's part on each is in view.
    @Test func aWindowAcrossTwoScreensIsSeenOnBoth() {
        let second = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let across = CGRect(x: 800, y: 100, width: 400, height: 200)
        let cover = WindowCover(window: across, screens: [screen, second], above: [CGRect(x: 1000, y: 100, width: 200, height: 200)])
        #expect(cover.covered == 0.5)
        // The other app in front on the first screen only: the video's window
        // on the second, in full view.
        let onSecond = CGRect(x: 1200, y: 100, width: 400, height: 200)
        #expect(WindowCover(window: onSecond, screens: [screen, second], above: [screen]).covered == 0)
    }

    /// Minimised, Nerda hidden, on another Space, or on no screen at all:
    /// nothing of it is in view.
    @Test func aHiddenWindowIsAllCovered() {
        let hidden = WindowCover(window: window, screens: [screen], above: [], hidden: true)
        #expect(hidden.covered == 1)
        #expect(hidden.hidesVideo)
        let nowhere = WindowCover(window: CGRect(x: 3000, y: 100, width: 400, height: 200), screens: [screen], above: [])
        #expect(nowhere.covered == 1)
        let empty = WindowCover(window: .zero, screens: [screen], above: [])
        #expect(empty.covered == 1)
    }

    /// Read from the screen, a window never put on it is hidden.
    @MainActor
    @Test func aWindowNeverShownReadsHidden() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(WindowCover.read(window).hidden)
        #expect(WindowCover.read(window).hidesVideo)
    }

    /// Of the windows the window server lists above, only those an app
    /// shows at the level of windows and panels, and not see-through, cover:
    /// not the menu bar, the Dock, the pointer or the desktop's widgets.
    @Test func onlyAppsOwnWindowsCover() {
        let bounds = CGRect(x: 1, y: 2, width: 3, height: 4)
        let listed: [WindowCover.Listed] = [
            .init(layer: 0, alpha: 1, bounds: bounds),
            .init(layer: 3, alpha: 0.9, bounds: bounds.offsetBy(dx: 10, dy: 0)),
            .init(layer: 0, alpha: 0, bounds: bounds.offsetBy(dx: 20, dy: 0)),
            .init(layer: 24, alpha: 1, bounds: bounds.offsetBy(dx: 30, dy: 0)),
            .init(layer: 20, alpha: 1, bounds: bounds.offsetBy(dx: 40, dy: 0)),
            .init(layer: -2147483601, alpha: 1, bounds: bounds.offsetBy(dx: 50, dy: 0)),
            .init(layer: 2147483630, alpha: 1, bounds: bounds.offsetBy(dx: 60, dy: 0)),
        ]
        #expect(WindowCover.covering(listed) == [bounds, bounds.offsetBy(dx: 10, dy: 0)])
    }
}
