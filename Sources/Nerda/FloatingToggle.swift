import WebKit

/// WebKit's own toggle for a page's main video, as Safari's menu bar and
/// Touch Bar use it: it carries its own click, as WebKit wants for picture
/// in picture, and acts on the video WebKit picks for the page's media
/// controls (playing with sound, large enough), in any of its frames, so an
/// embedded player floats too. It does nothing until its controls manager
/// is made ready, which WebKit does only for a Touch Bar.
// ponytail: WebKit SPI (WKWebViewPrivate), each call made only when the
// page answers to it. Should one go, Nerda floats by its script again
// (`ChosenVideo`), in the chosen video's own frame.
struct FloatingToggle {
    /// Makes ready the page's media controls manager, pointed at the video
    /// WebKit picks now (`_updateMediaPlaybackControlsManager`).
    var makeReady: @MainActor (WKWebView) -> Void
    /// Whether the toggle has a video to act on (`_canTogglePictureInPicture`).
    var canToggle: @MainActor (WKWebView) -> Bool
    /// Whether that video floats now, as WebKit has it (`_isPictureInPictureActive`).
    var isActive: @MainActor (WKWebView) -> Bool
    /// Floats that video, or lands it if it floats (`_togglePictureInPicture`).
    var toggle: @MainActor (WKWebView) -> Void
    /// Whether the page answers to all of them.
    var available: @MainActor (WKWebView) -> Bool

    private static let ready = NSSelectorFromString("_updateMediaPlaybackControlsManager")
    private static let can = NSSelectorFromString("_canTogglePictureInPicture")
    private static let active = NSSelectorFromString("_isPictureInPictureActive")
    private static let flip = NSSelectorFromString("_togglePictureInPicture")

    /// WebKit's, where the page answers to each call (`answers`: a test's
    /// own, to have them reported missing).
    static func webKit(answers: @escaping @MainActor (WKWebView, Selector) -> Bool = { $0.responds(to: $1) }) -> FloatingToggle {
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        typealias Ask = @convention(c) (AnyObject, Selector) -> Bool
        let call = { @MainActor (page: WKWebView, selector: Selector) in
            guard answers(page, selector) else { return }
            unsafeBitCast(page.method(for: selector), to: Call.self)(page, selector)
        }
        let ask = { @MainActor (page: WKWebView, selector: Selector) -> Bool in
            guard answers(page, selector) else { return false }
            return unsafeBitCast(page.method(for: selector), to: Ask.self)(page, selector)
        }
        return FloatingToggle(
            makeReady: { call($0, ready) },
            canToggle: { ask($0, can) },
            isActive: { ask($0, active) },
            toggle: { call($0, flip) },
            available: { page in [ready, can, active, flip].allSatisfy { answers(page, $0) } })
    }
}

/// Asking WebKit to float a tab's video as the owner leaves it, and to land
/// it as they come back: by WebKit's toggle where it can, else by the script.
/// One ask each time, never both. Each is timed in the record.
extension Browser {
    /// Asks WebKit to float `video`, of `tab`'s page (`videoToFloat`).
    /// Nothing while it floats already: the toggle would land it.
    func float(_ tab: Tab, _ video: PageVideo.ID) {
        guard let page = tab.page else { return }
        let toggle = floatingToggle
        let native = toggle.available(page)
        if tab.isFloating || (native && toggle.isActive(page)) { return }
        // The toggle floats WebKit's pick, a video playing with sound, so
        // only where that is the one heard. Made ready again here, as
        // WebKit's pick may have changed since the sound started.
        let heard = tab.videos.all.filter { $0.told.audible }
        if native, tab.playsAudio, heard.count == 1, heard.first?.id == video {
            toggle.makeReady(page)
            if toggle.canToggle(page) {
                toggle.toggle(page)
                askedToFloat(tab)
                return
            }
        }
        // Else by Nerda's script, in the video's own frame.
        page.evaluateJavaScript("nerdaVideos.float(\(video.element))", in: tab.videoFrames[video.frame], in: .defaultClient)
        askedToFloat(tab)
    }

    /// Asks WebKit to land `tab`'s video, if it floats.
    func land(_ tab: Tab) {
        guard let page = tab.page else { return }
        let toggle = floatingToggle
        // Never toggled when nothing floats: that would float it.
        if toggle.available(page), tab.isFloating || toggle.isActive(page), toggle.canToggle(page) {
            toggle.toggle(page)
        } else {
            // The main frame's, though it told of no video: one the page floated by its own button.
            page.evaluateJavaScript(PictureInPicture.exit)
            for frame in tab.videoFrames.values {
                page.evaluateJavaScript("globalThis.nerdaVideos?.land()", in: frame, in: .defaultClient)
            }
        }
        askedToLand(tab)
    }

    /// `tab`'s page started playing sound: what floating its video needs is
    /// made ready now, ahead of the owner leaving it. A page that plays no
    /// sound is never made ready; nor is an Agent browser's tab here, as
    /// nothing of its floats by itself.
    func soundStarted(_ tab: Tab) {
        guard !isForAgents, let page = tab.page, floatingToggle.available(page) else { return }
        floatingToggle.makeReady(page)
    }
}
