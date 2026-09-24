import WebKit

/// Full screen the way Chrome does it: the page's element (a video) takes the
/// whole window, and the window itself goes full screen, sidebar hidden. WebKit's
/// own full screen instead moves the page out into a window of its own, in a
/// space of its own, and leaves "Click to Exit Full Screen" behind in ours, with
/// no way to ask it not to. So pages are given a Fullscreen API of our own, which
/// lifts the element into the page's top layer (as a manual popover) and styles
/// it as WebKit styles `:fullscreen`. A frame's element takes its frame with it,
/// up to the page's; the page's tells the browser. WebKit's own stays underneath,
/// for what only it can reach: the button of a bare `<video controls>`.
// ponytail: a site's own `:fullscreen` CSS rules never match; the players that
// matter style themselves from `fullscreenchange`. Frames inside shadow roots
// can't be found to take along.
enum Fullscreen {
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    static let messages = Messages()
    /// What takes a page out of full screen, as its own Esc would.
    static let exit = "document.exitFullscreen().catch(() => {})"

    /// The page's word that it went full screen (true) or came back, for the browser showing it.
    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Frames go through the page, which checks they are allowed to.
            guard message.frameInfo.isMainFrame, let page = message.webView else { return }
            (page.uiDelegate as? Browser)?.page(page, wantsFullscreen: message.body as? Bool == true)
        }
    }

    private static let source = #"""
        (() => {
            const browser = window.webkit?.messageHandlers?.fullscreen;
            const marker = 'data-nerda-fullscreen';
            const key = 'nerda-fullscreen';
            const nativeExit = Document.prototype.exitFullscreen;
            // Made on first use: most frames (ads, widgets) never go full screen.
            let sheet = null;
            const css = `
                [${marker}]:not(:root) {
                    object-fit: contain;
                    position: fixed !important;
                    inset: 0 !important;
                    margin: 0 !important;
                    box-sizing: border-box !important;
                    min-width: 0 !important;
                    max-width: none !important;
                    min-height: 0 !important;
                    max-height: none !important;
                    width: 100% !important;
                    height: 100% !important;
                    transform: none !important;
                    z-index: 2147483647 !important;
                }
                iframe[${marker}] { border: none !important; padding: 0 !important; }
                /* Undoes what being a popover adds, where the site says nothing itself. */
                :where([${marker}]) { border: none; padding: 0; overflow: visible; color: inherit; background-color: transparent; }
                [${marker}]::backdrop { background: black !important; }
            `;
            // This document's element on show, and whether the popover attribute is ours.
            let shown = null;
            let ownPopover = false;
            // Where the page was, to go back to: the element's place on screen, as the page may lay out
            // differently by then (the window is another size), and it scrolls behind while on show.
            let place = null;
            const goBack = () => {
                if (!place || shown) return;
                const { element, top, x, y } = place;
                if (element.isConnected && element !== document.documentElement) scrollBy(0, element.getBoundingClientRect().top - top);
                else scrollTo(x, y);
            };
            // Again as the window comes back to size, for a moment.
            let settling = 0;
            const settle = () => {
                goBack();
                addEventListener('resize', goBack);
                settling = setTimeout(settled, 1000);
            };
            const settled = () => {
                clearTimeout(settling);
                removeEventListener('resize', goBack);
                place = null;
            };
            // An element taken out of the page takes the page out of full screen.
            const watcher = new MutationObserver(() => { if (shown && !shown.isConnected) exit(); });

            const fire = (element, type) => setTimeout(() => {
                const target = element.isConnected ? element : document;
                for (const name of [type, 'webkit' + type]) target.dispatchEvent(new Event(name, { bubbles: true, composed: true }));
            });
            // The frame this document is in shows that frame too, and so on up to the page's, which tells the browser.
            const tellUp = (what) => window === top ? browser?.postMessage(what === 'enter') : parent.postMessage({ [key]: what }, '*');

            function show(element) {
                if (shown === element) return;
                if (shown) unshow(true);
                else {
                    settled();
                    place = { element, top: element.getBoundingClientRect().top, x: scrollX, y: scrollY };
                }
                shown = element;
                if (!sheet) { sheet = new CSSStyleSheet(); sheet.replaceSync(css); }
                if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
                element.setAttribute(marker, '');
                if (element !== document.documentElement && element.showPopover && !element.hasAttribute('popover')) {
                    element.setAttribute('popover', 'manual');
                    ownPopover = true;
                    try { element.showPopover(); } catch {}
                }
                watcher.observe(document, { childList: true, subtree: true });
                fire(element, 'fullscreenchange');
                tellUp('enter');
            }

            // Puts the element back, and whatever a frame shown was showing inside it; and, unless
            // another element takes its place, the page back where it was.
            function unshow(swapping) {
                const element = shown;
                shown = null;
                watcher.disconnect();
                element.removeAttribute(marker);
                if (ownPopover) {
                    try { element.hidePopover(); } catch {}
                    element.removeAttribute('popover');
                    ownPopover = false;
                }
                element.contentWindow?.postMessage({ [key]: 'exit' }, '*');
                if (!swapping) settle();
                fire(element, 'fullscreenchange');
            }

            function exit() {
                if (!shown) return;
                unshow();
                tellUp('exit');
            }

            // As a document, or a shadow root, sees the element: from outside its shadow root, as that root's host.
            const seenFrom = (root) => {
                for (let element = shown; element; element = element.getRootNode().host) {
                    if (element.getRootNode() === root) return element;
                }
                return null;
            };

            function request() {
                const element = this;
                // As WebKit's: only on a click or key press, and only in frames allowed to.
                if (!element.isConnected || document.fullscreenEnabled === false || navigator.userActivation?.isActive === false) {
                    fire(element, 'fullscreenerror');
                    return Promise.reject(new TypeError('Not allowed to enter full screen.'));
                }
                show(element);
                return new Promise((resolve) => setTimeout(resolve));
            }

            const define = (prototype, name, get) => Object.defineProperty(prototype, name, { get, configurable: true, enumerable: true });
            for (const prototype of [Document.prototype, ShadowRoot.prototype]) {
                const native = Object.getOwnPropertyDescriptor(prototype, 'fullscreenElement')?.get;
                const get = function () { return seenFrom(this) ?? native?.call(this) ?? null; };
                for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) define(prototype, name, get);
            }
            for (const name of ['fullscreen', 'webkitIsFullScreen']) define(Document.prototype, name, function () { return !!this.fullscreenElement; });

            const quietly = function () { request.call(this).catch(() => {}); };
            Element.prototype.requestFullscreen = request;
            Element.prototype.webkitRequestFullscreen = Element.prototype.webkitRequestFullScreen = quietly;
            Document.prototype.exitFullscreen = function () {
                if (!shown) return nativeExit ? nativeExit.call(this) : Promise.reject(new TypeError('Not in full screen.'));
                exit();
                return new Promise((resolve) => setTimeout(resolve));
            };
            Document.prototype.webkitExitFullscreen = Document.prototype.webkitCancelFullScreen = function () { this.exitFullscreen().catch(() => {}); };

            const video = HTMLVideoElement.prototype;
            video.webkitEnterFullscreen = video.webkitEnterFullScreen = quietly;
            video.webkitExitFullscreen = video.webkitExitFullScreen = function () { if (shown === this) exit(); };
            define(video, 'webkitDisplayingFullscreen', function () { return shown === this; });

            // Between frames. Registered before any of the page's, so the page never sees these.
            addEventListener('message', (event) => {
                const what = event.data?.[key];
                if (!what) return;
                event.stopImmediatePropagation();
                if (what === 'enter') {
                    const frame = [...document.querySelectorAll('iframe, frame')].find((frame) => frame.contentWindow === event.source);
                    if (!frame) return;
                    // A frame from another site only with allowfullscreen, as WebKit has it.
                    if (frame.allowFullscreen || /\bfullscreen\b/.test(frame.allow ?? '') || frame.contentDocument) show(frame);
                    else event.source.postMessage({ [key]: 'exit' }, '*');
                } else if (what === 'exit') {
                    if (window !== top && event.source === parent) { if (shown) unshow(); }
                    else if (shown && shown.contentWindow === event.source) exit();
                } else if (what === 'escape' && window === top) {
                    exit();
                }
            }, true);

            // Esc always comes back, whatever the page does with it, from whichever frame has the keyboard.
            addEventListener('keydown', (event) => {
                if (event.key !== 'Escape') return;
                if (window !== top) return top.postMessage({ [key]: 'escape' }, '*');
                // Also when the browser went full screen for the page without the page showing anything.
                if (shown) exit(); else browser?.postMessage(false);
            }, true);
        })();
        """#
}

extension WKWebView {
    /// Whether the page hears that its window is covered, which WebKit takes
    /// for hidden: it pauses the page's video. Turned off while the window goes
    /// in or out of full screen, when macOS covers it with its own animation.
    // ponytail: WebKit SPI, as its own full screen does the same inside WebKit.
    // Should it go, videos only pause for the animation again.
    func hearsWindowCovered(_ hears: Bool) {
        let setter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard responds(to: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: setter), to: Setter.self)(self, setter, hears)
    }
}
