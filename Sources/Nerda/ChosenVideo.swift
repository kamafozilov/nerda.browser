import Foundation
import WebKit

/// One video of a page, as its frame last told Nerda (`ChosenVideo.script`),
/// and how long it has been heard, on Nerda's clock.
struct PageVideo: Equatable, Sendable {
    /// The frame's own name for its document, and the element's number in it.
    struct ID: Hashable, Sendable {
        var frame: String
        var element: Int
    }

    var id: ID
    var told: PageVideos.Told
    /// Seconds it played with sound before `heardSince`.
    var heard: TimeInterval = 0
    /// When it last began to be heard, while it is.
    var heardSince: TimeInterval?

    /// Seconds it has played with sound by `now`.
    func heard(at now: TimeInterval) -> TimeInterval {
        heard + (heardSince.map { max(0, now - $0) } ?? 0)
    }
}

/// The videos of a tab's page, frame by frame, as each frame last told.
struct PageVideos: Equatable, Sendable {
    /// A frame's word for one of its videos.
    struct Told: Equatable, Sendable {
        var element: Int
        /// Not paused, not ended.
        var playing: Bool
        /// Muted, or at volume 0.
        var muted: Bool
        /// It has a sound track.
        var hasSound: Bool
        /// It has a picture: sound alone in a video element (a podcast) has none.
        var hasPicture: Bool
        /// The owner started it or turned its sound on: a click, a key, or
        /// Nerda on their behalf, never the page by itself.
        var ownerStarted: Bool
        /// What it takes of its page, in CSS pixels squared.
        var area: Double

        /// Could be heard now, the tab's own mute aside.
        var audible: Bool { playing && !muted && hasSound }
    }

    private(set) var all: [PageVideo] = []

    /// What `frame` says of its videos at `now`: all it has, those it
    /// doesn't name are gone.
    mutating func heard(frame: String, _ videos: [Told], at now: TimeInterval) {
        let before = all.filter { $0.id.frame == frame }
        gone(frame: frame)
        for told in videos {
            let id = PageVideo.ID(frame: frame, element: told.element)
            var video = before.first { $0.id == id } ?? PageVideo(id: id, told: told)
            if video.told.audible, !told.audible { video.heard = video.heard(at: now); video.heardSince = nil }
            if told.audible, video.heardSince == nil { video.heardSince = now }
            video.told = told
            all.append(video)
        }
    }

    /// `frame`'s document went: a new one, or the frame taken out.
    mutating func gone(frame: String) {
        all.removeAll { $0.id.frame == frame }
    }
}

/// Which video floats by itself as the owner leaves its tab (Auto
/// Picture-in-Picture): only one they chose to watch. It plays with sound,
/// they started it or turned its sound on, and it has been heard for three
/// seconds; of several, the largest. Never a muted one, nor in a muted tab,
/// nor in an Agent tab, nor sound with no picture.
enum FloatingRule {
    /// Seconds of play with sound before a video may float.
    static let heardAtLeast: TimeInterval = 3

    static func video(among videos: [PageVideo], at now: TimeInterval, on: Bool, tabMuted: Bool,
                      agentTab: Bool) -> PageVideo.ID? {
        guard on, !tabMuted, !agentTab else { return nil }
        return videos
            .filter { $0.told.audible && $0.told.hasPicture && $0.told.ownerStarted && $0.heard(at: now) >= heardAtLeast }
            .max { $0.told.area < $1.told.area }?.id
    }
}

/// How a page tells Nerda of its videos (`PageVideos`), frame by frame,
/// and how the one chosen floats and lands. A script in Nerda's own world
/// in every frame tells, as a video starts, stops, is muted or unmuted or
/// changes size, every video it has heard from; the page can't see it or
/// what it says. It takes a play or an unmute for the owner's while their
/// click or key is still in effect (`navigator.userActivation`): heard in
/// the media's own event, and, for Nerda's own scripts acting for them,
/// at the call itself, which a small hook in the page's world marks.
enum ChosenVideo {
    static let script = WKUserScript(source: """
        (() => {
            // The frame's document: another name in its next one. Not
            // randomUUID, which an http page hasn't.
            const frame = [...crypto.getRandomValues(new Uint32Array(4))].map(n => n.toString(36)).join('');
            const numbers = new WeakMap(), elements = new Map(), started = new WeakSet();
            let count = 0, queued = false;
            const owners = () => navigator.userActivation?.isActive === true;
            const audible = video => !video.muted && video.volume > 0;
            const post = body => webkit.messageHandlers.videos.postMessage(body);
            const tell = () => {
                if (queued) return;
                queued = true;
                queueMicrotask(() => {
                    queued = false;
                    const videos = [];
                    for (const [element, held] of elements) {
                        const video = held.deref();
                        if (!video?.isConnected) {
                            elements.delete(element);
                            if (video) sizes.unobserve(video);
                            continue;
                        }
                        const box = video.getBoundingClientRect();
                        videos.push({
                            element, playing: !video.paused && !video.ended, muted: !audible(video),
                            hasSound: video.audioTracks ? video.audioTracks.length > 0 : true,
                            hasPicture: video.videoWidth > 0 && video.videoHeight > 0,
                            ownerStarted: started.has(video), area: box.width * box.height,
                        });
                    }
                    post({ frame, videos });
                });
            };
            const sizes = new ResizeObserver(tell);
            const heard = event => {
                // Down open shadow roots too: their media events stop at the root's host.
                const video = event.composedPath?.()[0] ?? event.target;
                if (!(video instanceof HTMLVideoElement)) return;
                if (!numbers.has(video)) {
                    numbers.set(video, ++count);
                    elements.set(count, new WeakRef(video));
                    sizes.observe(video);
                }
                // Started, or its sound turned on as it plays, at the owner's word.
                const sound = event.type === 'volumechange' || event.type === 'nerdasound';
                const asked = event.type === 'play' || event.type === 'nerdaplay' || (sound && !video.paused && audible(video));
                if (asked && owners()) started.add(video);
                tell();
            };
            for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadedmetadata', 'resize', 'emptied', 'nerdaplay', 'nerdasound'])
                addEventListener(type, heard, true);
            addEventListener('pagehide', () => post({ frame, gone: true }));
            addEventListener('pageshow', event => { if (event.persisted) tell(); });
            const number = element => elements.get(element)?.deref();
            globalThis.nerdaVideos = {
                float(element) {
                    const video = number(element);
                    if (video?.webkitSupportsPresentationMode?.('picture-in-picture')) video.webkitSetPresentationMode('picture-in-picture');
                },
                land() {
                    for (const video of document.querySelectorAll('video'))
                        if (video.webkitPresentationMode === 'picture-in-picture') video.webkitSetPresentationMode('inline');
                },
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// In the page's world: each play() and each change of mute or volume
    /// is marked on its element as it is made, so Nerda's own world hears
    /// it while whatever asked for it is still in effect. Added after
    /// `Tab.unseenMedia`, so its held play() is the one marked.
    // ponytail: a page's script can see the hook, and mark a call itself:
    // heard only while the owner's click or key is in effect, as theirs.
    static let hook = WKUserScript(source: """
        (() => {
            const media = HTMLMediaElement.prototype;
            const mark = (element, type) => element.dispatchEvent(new Event(type));
            const { play } = media;
            media.play = function () {
                const playing = play.apply(this, arguments);
                mark(this, 'nerdaplay');
                return playing;
            };
            for (const name of ['muted', 'volume']) {
                const { get, set } = Object.getOwnPropertyDescriptor(media, name);
                Object.defineProperty(media, name, {
                    get, set(value) { set.call(this, value); mark(this, 'nerdasound'); }, configurable: true, enumerable: true,
                });
            }
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    static let messages = Messages()

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.addUserScript(hook)
        controller.add(messages, contentWorld: .defaultClient, name: "videos")
    }

    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let frame = body["frame"] as? String,
                  let page = message.webView, let browser = page.uiDelegate as? Browser,
                  let tab = browser.tab(for: page) else { return }
            if body["gone"] as? Bool == true { return tab.videosGone(frame: frame) }
            let videos = (body["videos"] as? [[String: Any]] ?? []).compactMap(PageVideos.Told.init)
            tab.heardVideos(frame: frame, in: message.frameInfo, videos, at: browser.videoClock())
        }
    }
}

extension PageVideos.Told {
    /// From the page's word, as the script above writes it.
    init?(_ told: [String: Any]) {
        guard let element = told["element"] as? Int else { return nil }
        self.init(element: element, playing: told["playing"] as? Bool ?? false, muted: told["muted"] as? Bool ?? true,
                  hasSound: told["hasSound"] as? Bool ?? false, hasPicture: told["hasPicture"] as? Bool ?? false,
                  ownerStarted: told["ownerStarted"] as? Bool ?? false, area: told["area"] as? Double ?? 0)
    }
}

/// Floating by itself, as the owner leaves a tab or Nerda, and landing as
/// they come back: the one place both ask, so the rule holds for each.
extension Browser {
    /// The video that would float were `tab` left now (`FloatingRule`).
    func videoToFloat(in tab: Tab) -> PageVideo.ID? {
        guard tab.page != nil else { return nil }
        return FloatingRule.video(among: tab.videos.all, at: videoClock(), on: PictureInPicture.isOn(in: pictureInPictureSettings),
                                  tabMuted: tab.isMuted, agentTab: isForAgents)
    }

    /// The owner left `tab`: its video floats if it is one they chose
    /// (`float`). Whether it asked. One floats at a time without more: the
    /// system's floating window is one for the app, so another floating
    /// lands the first, in whichever window or profile (`oneVideoFloatsAtATime`).
    @discardableResult
    func ownerLeft(_ tab: Tab) -> Bool {
        guard let video = videoToFloat(in: tab) else { return false }
        float(tab, video)
        return true
    }

    /// The owner came back to `tab`: its video lands in its page (`land`).
    func ownerCameBack(to tab: Tab) {
        guard PictureInPicture.isOn(in: pictureInPictureSettings), tab.page != nil else { return }
        land(tab)
    }
}
