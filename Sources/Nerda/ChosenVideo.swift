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
    /// It is in the page's main frame, not a frame in it.
    var inMainFrame = true
    /// When it was first heard, on Nerda's clock; nil until it is.
    var firstHeard: TimeInterval?
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
    /// `main`: the frame is the page's main frame.
    mutating func heard(frame: String, main: Bool, _ videos: [Told], at now: TimeInterval) {
        let before = all.filter { $0.id.frame == frame }
        gone(frame: frame)
        for told in videos {
            let id = PageVideo.ID(frame: frame, element: told.element)
            var video = before.first { $0.id == id } ?? PageVideo(id: id, told: told, inMainFrame: main)
            if video.told.audible, !told.audible { video.heard = video.heard(at: now); video.heardSince = nil }
            if told.audible, video.heardSince == nil { video.heardSince = now }
            if told.audible, video.firstHeard == nil { video.firstHeard = now }
            video.told = told
            all.append(video)
        }
    }

    /// `frame`'s document went: a new one, or the frame taken out.
    mutating func gone(frame: String) {
        all.removeAll { $0.id.frame == frame }
    }
}

/// What Nerda knows of the document in a tab's main frame, on its clock:
/// how it came, and since when the owner could see it.
struct PageDocument: Equatable, Sendable {
    /// The owner went to it: a link they clicked, an address, a bookmark, a
    /// link from another app, back, forward or reload. Not where the page
    /// itself went (a script's redirect).
    var ownersNavigation = false
    /// It came in out of sight (a tab opened behind, a page loaded hidden).
    var startedOutOfSight = false
    /// Since when it has been in sight: as it came in, or since the owner
    /// brought its tab into sight; nil while it never has been.
    var inSightSince: TimeInterval?

    /// Whether a video of its main frame first heard at `heard` started as
    /// the owner went to the page or brought it into sight: within its
    /// first moments in sight (`FloatingRule.firstMoments`).
    func startedForTheOwner(heard: TimeInterval) -> Bool {
        guard ownersNavigation || startedOutOfSight, let since = inSightSince else { return false }
        return heard - since <= FloatingRule.firstMoments
    }
}

/// Which video floats by itself as the owner leaves its tab (Auto
/// Picture-in-Picture): only one they chose to watch. It plays with sound,
/// and has been heard for three seconds; they started it or turned its
/// sound on, or it started with sound in the page's first moments in sight
/// of a page they went to or brought into sight (`PageDocument`); of
/// several, the largest. Never a muted one, nor in a muted tab, nor in an
/// Agent tab, nor sound with no picture.
enum FloatingRule {
    /// Seconds of play with sound before a video may float.
    static let heardAtLeast: TimeInterval = 3
    /// Seconds from a page coming into sight within which a video that
    /// starts with sound is taken as the owner's choice in going there.
    static let firstMoments: TimeInterval = 10

    static func video(among videos: [PageVideo], in document: PageDocument = PageDocument(), at now: TimeInterval,
                      on: Bool, tabMuted: Bool, agentTab: Bool) -> PageVideo.ID? {
        guard on, !tabMuted, !agentTab else { return nil }
        return videos
            .filter { $0.told.audible && $0.told.hasPicture && chosen($0, in: document) && $0.heard(at: now) >= heardAtLeast }
            .max { $0.told.area < $1.told.area }?.id
    }

    private static func chosen(_ video: PageVideo, in document: PageDocument) -> Bool {
        if video.told.ownerStarted { return true }
        guard video.inMainFrame, let heard = video.firstHeard else { return false }
        return document.startedForTheOwner(heard: heard)
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
            const numbers = new WeakMap(), elements = new Map(), started = new WeakSet(), calls = new WeakMap();
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
                    // A sound track can come after the media's own events (measured).
                    video.audioTracks?.addEventListener('addtrack', tell);
                    video.audioTracks?.addEventListener('removetrack', tell);
                }
                // Started, or its sound turned on as it plays, at the owner's
                // word. A call through the page's play() or its setters is
                // judged as it is made (`hook`), and the media event it
                // brings is its own: later, Nerda's own scripts (an icon
                // looked up) may read as an input in effect. The event alone
                // judges what bypassed them, as WebKit's own controls do.
                const now = performance.now();
                const play = event.type === 'play' || event.type === 'nerdaplay';
                const kind = play ? 'play' : 'sound';
                const asked = play || ((event.type === 'volumechange' || event.type === 'nerdasound') && !video.paused && audible(video));
                if (event.type === 'nerdaplay' || event.type === 'nerdasound') {
                    calls.set(video, { ...calls.get(video), [kind]: now });
                    if (asked && owners()) started.add(video);
                } else if (asked || event.type === 'volumechange') {
                    const call = calls.get(video)?.[kind];
                    if (call !== undefined && now - call < 1000) calls.set(video, { ...calls.get(video), [kind]: undefined });
                    else if (asked && owners()) started.add(video);
                }
                tell();
            };
            for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadedmetadata', 'resize', 'emptied', 'nerdaplay', 'nerdasound'])
                addEventListener(type, heard, true);
            addEventListener('pagehide', () => post({ frame, gone: true }));
            addEventListener('pageshow', event => { if (event.persisted) tell(); });
            const number = element => elements.get(element)?.deref();
            globalThis.nerdaVideos = {
                // Each answers whether it found a video to ask.
                float(element) {
                    const video = number(element);
                    if (!video?.webkitSupportsPresentationMode?.('picture-in-picture')) return false;
                    video.webkitSetPresentationMode('picture-in-picture');
                    return true;
                },
                land() {
                    const floating = [...document.querySelectorAll('video')].filter(video => video.webkitPresentationMode === 'picture-in-picture');
                    for (const video of floating) video.webkitSetPresentationMode('inline');
                    return floating.length > 0;
                },
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// In the page's world: each play() and each change of mute or volume
    /// is marked on its element as it is made, so Nerda's own world hears
    /// it while whatever asked for it is still in effect. Added before
    /// `Tab.unseenMedia`, which holds a hidden page's play() and gives this
    /// one back once shown.
    // ponytail: a page's script can see the hook, and mark a call itself:
    // heard only while the owner's click or key is in effect, as theirs.
    static let hook = WKUserScript(source: """
        (() => {
            const media = HTMLMediaElement.prototype;
            const mark = (element, type) => element.dispatchEvent(new Event(type));
            const { play } = media;
            // Marked only where the call brings a media event of its own.
            media.play = function () {
                if (this.paused) mark(this, 'nerdaplay');
                return play.apply(this, arguments);
            };
            for (const name of ['muted', 'volume']) {
                const { get, set } = Object.getOwnPropertyDescriptor(media, name);
                Object.defineProperty(media, name, {
                    get,
                    set(value) {
                        const was = get.call(this);
                        set.call(this, value);
                        if (get.call(this) !== was) mark(this, 'nerdasound');
                    },
                    configurable: true, enumerable: true,
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
            tab.heardVideos(frame: frame, in: message.frameInfo, main: message.frameInfo.isMainFrame, videos, at: browser.videoClock())
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

extension Browser {
    /// The video that would float were `tab` left now (`FloatingRule`): what
    /// `float` floats, and `floats(leaving:)` keeps in sight for.
    func videoToFloat(in tab: Tab) -> PageVideo.ID? {
        guard tab.page != nil else { return nil }
        // A test's say in the rule's place: the page's first video, or none named.
        if let floatsOnLeaving {
            return floatsOnLeaving(tab) ? tab.videos.all.first?.id ?? PageVideo.ID(frame: "", element: 0) : nil
        }
        return FloatingRule.video(among: tab.videos.all, in: tab.document, at: videoClock(),
                                  on: PictureInPicture.isOn(in: pictureInPictureSettings), tabMuted: tab.isMuted, agentTab: isForAgents)
    }
}
