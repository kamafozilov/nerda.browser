import AppKit

/// Which of the owner's browser windows is in front, so that a video
/// floats as its window is left and lands as it comes back: another of
/// Nerda's windows coming forward leaves the one in front before it, and a
/// window going into the Dock is left at once. Told by each window's
/// `AppDelegate`; one for the app, a test's own.
@MainActor
final class WindowInFront {
    static let app = WindowInFront()

    /// The browser whose window is in front, as far as Nerda's windows go:
    /// still this one while another app is in front.
    private(set) weak var front: Browser?

    /// `browser`'s window is now the main one: the one in front before it is
    /// left for it, and its own tab come back to. The same window again
    /// (Nerda left for another app and back) leaves nothing.
    func cameForward(_ browser: Browser) {
        if let before = front, before !== browser { before.windowLeft() }
        front = browser
        browser.windowCameBack()
    }

    /// `browser`'s window is going into the Dock: left at once, while its
    /// page is still on screen, and no longer in front, so the window that
    /// comes forward after it leaves nothing more.
    func putAway(_ browser: Browser) {
        if front === browser { front = nil }
        browser.windowLeft()
    }

    /// Nerda is being left for another app: the video of the window in front
    /// floats, with "Also when switching to another app" on, an incognito
    /// window's too.
    func appLeft() {
        guard let browser = front, PictureInPicture.isOnForApps(in: browser.pictureInPictureSettings) else { return }
        browser.windowLeft()
    }

    /// Back in Nerda: the video of the window in front lands, and only that
    /// one. Come back to through another window, the one left keeps its
    /// video floating; told before or after that window is in front, it
    /// ends the same.
    func appCameBack() {
        front?.windowCameBack()
    }

    /// `browser`'s window closed: no window to leave as the next comes forward.
    func closed(_ browser: Browser) {
        if front === browser { front = nil }
    }
}
