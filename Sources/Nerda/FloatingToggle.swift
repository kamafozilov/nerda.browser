import WebKit

/// WebKit's own toggle for a page's main video, as Safari's menu bar and
/// Touch Bar use it: it carries its own click, as WebKit wants for picture
/// in picture, and acts on the video WebKit picks for the page's media
/// controls (playing with sound, large enough), in any of its frames, so an
/// embedded player floats too. It does nothing until its controls manager
/// is made ready, which WebKit does only for a Touch Bar.
// ponytail: WebKit SPI (WKWebViewPrivate), each call made only when the
// page answers to it. Should one go, Nerda floats by its script again
// (`PictureInPicture.enter`): the page's own frame only.
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

/// A change Nerda asked of WebKit for a tab's video, to float it or land it,
/// that WebKit hasn't yet said is done. One that goes unanswered longer
/// than `Recorder.presentingLongest` was never taken up, and holds up
/// nothing after it.
struct FloatingAsk {
    /// To float, or to land.
    let floats: Bool
    /// When, on the browser's `floatingClock`.
    let at: TimeInterval
    /// Which ask, for the script's answer to find it (`Browser.ask`).
    let number: Int

    func isUnderWay(at now: TimeInterval) -> Bool { now - at < Recorder.presentingLongest }
}

/// Where a tab's video goes follows where the owner is: `float` as they
/// leave it, `land` as they come back, however quickly. Each sets what the
/// owner wants beside what WebKit last said (`Tab.wantsFloating`,
/// `Tab.isFloating`) and asks WebKit for it, unless a change Nerda asked
/// for is under way: WebKit ignores an ask then, so the next is made once
/// WebKit says that change is done (`heard`). WebKit's toggle where it can,
/// else the script; one ask at a time, never both. The owner's own moves
/// are timed in the record; the asks that follow on from WebKit's word are not.
extension Browser {
    /// The owner left `tab`: its video is to float. Timed from now, asked
    /// now or once the change under way is done; not when it floats already.
    func float(_ tab: Tab) {
        tab.wantsFloating = true
        if follow(tab) || tab.floatingAsked != nil { askedToFloat(tab) }
    }

    /// The owner came back to `tab`: its video is to be in its page.
    func land(_ tab: Tab) {
        tab.wantsFloating = false
        follow(tab)
        askedToLand(tab)
    }

    /// WebKit's word that `tab`'s video floats now, or is in its page. The
    /// end of a change Nerda asked for: what the owner wants now is asked
    /// next, if it differs. With nothing asked, it was the owner's own doing
    /// in the system's floating window, or the page's: taken as their want.
    func heard(_ tab: Tab, floating: Bool) {
        guard tab.floatingAsked != nil else {
            tab.wantsFloating = floating
            return
        }
        tab.floatingAsked = nil
        // On the next turn of the main loop: asked while WebKit is still
        // telling this, WebKit drops the ask, and the toggles after it too.
        DispatchQueue.main.async { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.follow(tab)
            }
        }
    }

    /// Asks WebKit for where the owner wants `tab`'s video, unless a change
    /// asked for is still under way. Whether it asked.
    @discardableResult
    private func follow(_ tab: Tab) -> Bool {
        guard let page = tab.page else { return false }
        if let asked = tab.floatingAsked, asked.isUnderWay(at: floatingClock()) { return false }
        tab.floatingAsked = nil
        return tab.wantsFloating ? askToFloat(tab, page) : askToLand(tab, page)
    }

    /// Nothing while it floats already: the toggle would land it.
    private func askToFloat(_ tab: Tab, _ page: WKWebView) -> Bool {
        let toggle = floatingToggle
        let native = toggle.available(page)
        if tab.isFloating || (native && toggle.isActive(page)) { return false }
        // Only a page playing sound has a video to keep hearing; the toggle
        // would float a paused one. Made ready again here, as WebKit's pick
        // may have changed since the sound started.
        if native, tab.playsAudio {
            toggle.makeReady(page)
            if toggle.canToggle(page) {
                toggle.toggle(page)
                asked(tab, floats: true)
                return true
            }
        }
        ask(tab, floats: true, by: PictureInPicture.enter, in: page)
        return true
    }

    /// Never toggled when nothing floats: that would float it. The script
    /// then still runs, as before WebKit's word: it does nothing where no
    /// video floats.
    private func askToLand(_ tab: Tab, _ page: WKWebView) -> Bool {
        let toggle = floatingToggle
        if toggle.available(page), tab.isFloating || toggle.isActive(page), toggle.canToggle(page) {
            toggle.toggle(page)
            asked(tab, floats: false)
            return true
        }
        if tab.isFloating {
            ask(tab, floats: false, by: PictureInPicture.exit, in: page)
        } else {
            page.evaluateJavaScript(PictureInPicture.exit)
        }
        return true
    }

    private func asked(_ tab: Tab, floats: Bool) {
        floatingAsks += 1
        tab.floatingAsked = FloatingAsk(floats: floats, at: floatingClock(), number: floatingAsks)
    }

    /// By the script, which answers whether it found a video to ask: one
    /// that found none started nothing, and holds up nothing after it.
    private func ask(_ tab: Tab, floats: Bool, by script: String, in page: WKWebView) {
        asked(tab, floats: floats)
        let number = floatingAsks
        page.evaluateJavaScript(script) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                guard let self, let tab, answer as? Bool != true, tab.floatingAsked?.number == number else { return }
                tab.floatingAsked = nil
                // Asked again only if the owner changed their mind meanwhile.
                if tab.wantsFloating != floats { self.follow(tab) }
            }
        }
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
