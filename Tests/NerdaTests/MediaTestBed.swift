import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Nerda

/// What a test bed page plays, all of it made as the test runs.
enum BedMedia: Sendable, Hashable {
    /// A movie file in `<video src>`, which WebKit plays through AVPlayer:
    /// long enough that no wait of a test reaches its end.
    case file(seconds: Double = 30, sound: GeneratedSound = .tone(hertz: 440))
}

/// The media test bed: a browser in a plain window of its own, behind the
/// windows in use, its pages served from this Mac (`MediaServer`) and
/// playing media generated as the test runs (`BedMedia`), at a volume
/// nobody hears. Every test of media in a real page starts here:
///
///     let bed = try await MediaTestBed()
///     defer { bed.close() }
///     let page = try await bed.play(.file())
///     let clock = try await page.clock(around: { try await page.pause(); try await page.play() })
///     #expect(clock.jumps(over: MediaClock.tolerance).isEmpty)
///
/// Suites that use it are `.serialized`.
@MainActor
final class MediaTestBed {
    /// The element's volume on every bed page: playing with sound, as far as
    /// WebKit and Nerda can tell, and with the sound's own level (−20 dB) at
    /// −80 dB, not heard.
    static let inaudible = 0.001

    let server: MediaServer
    let browser: Browser
    let window: NSWindow
    private var pages = 0
    /// Serves the pages that hold a bed page in a frame, from another port:
    /// another origin, as a player embedded on another site is.
    private var framing: MediaServer?

    init() async throws {
        server = try MediaServer()
        browser = browserRunningOutOfSight()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(browser: browser, window: window))
        window.orderBack(nil)
        _ = try await server.url()
    }

    /// A new tab, shown, with a page playing `media`, started by a script
    /// from Nerda as the owner's click would: once it plays, its media time
    /// has moved on.
    func play(_ media: BedMedia, inFrame: Bool = false) async throws -> MediaPage {
        let page = try await open(media, inFrame: inFrame)
        try await page.play()
        return page
    }

    /// A new tab, shown, with a page holding `media`, ready to play; `inFrame`,
    /// the bed page is in a frame of a page from another origin, with nothing
    /// else in it, and the bed's scripts run in that frame.
    func open(_ media: BedMedia, inFrame: Bool = false) async throws -> MediaPage {
        pages += 1
        let source = try await serve(media, as: "/media/\(pages)")
        var url = try await server.serve("/page/\(pages)", html: MediaPage.html(source: source))
        if inFrame {
            let framing = try self.framing ?? MediaServer()
            self.framing = framing
            url = try await framing.serve("/embed/\(pages)", html: MediaPage.embedding(url))
        }
        let tab = browser.open(URL(string: "about:blank")!)
        // The window is behind the owner's, often covered by them: a page in
        // it hearing so would be hidden to WebKit, which pauses its video,
        // and Nerda would hold its play() until shown (`Tab.unseenMedia`).
        tab.webView.hearsWindowCovered(false)
        try await waitFor("The tab never joined the bed's window") { tab.webView.window === window }
        tab.go(to: url)
        let page = MediaPage(tab: tab)
        try await waitFor("The bed's page never loaded with its media") {
            guard tab.webView.url == url, !tab.webView.isLoading else { return false }
            if inFrame {
                page.frame = await MediaPage.firstFrame(in: tab.webView)
                guard page.frame != nil else { return false }
            }
            return try await page.state().readyState >= 1
        }
        return page
    }

    /// Serves what `media` needs under `path`, and answers what the page's
    /// `<video>` is to play.
    private func serve(_ media: BedMedia, as path: String) async throws -> MediaPage.Source {
        switch media {
        case .file(let seconds, let sound):
            let movie = try await GeneratedMovie.mp4(seconds: seconds, sound: sound)
            return .src(try await server.serve("\(path).mp4", movie, type: "video/mp4"))
        }
    }

    func close() {
        for tab in browser.tabs { browser.close(tab.id) }
        window.close()
        server.stop()
        framing?.stop()
    }
}

/// A bed page in its tab: its one `<video>`, what can be done to it, and its
/// clock (`clock(around:)`). The page samples the element's clock every
/// 20 ms and at each of its events, and marks each action as it is done.
@MainActor
final class MediaPage {
    let tab: Nerda.Tab
    /// The frame the bed page is in, when it is in one (`MediaTestBed.open(_:inFrame:)`).
    var frame: WKFrameInfo?

    init(tab: Nerda.Tab) { self.tab = tab }

    /// How the element stands now.
    struct State: Decodable {
        var media: Double
        var paused: Bool
        var rate: Double
        var volume: Double
        var muted: Bool
        var readyState: Int
        var videoWidth: Int
        var videoHeight: Int
        /// Whether the media has a sound track, as WebKit sees it.
        var hasSound: Bool
    }

    func state() async throws -> State {
        try await read("bed.state()")
    }

    /// Plays from where it is, and returns once it plays. Refuses to while
    /// the page could be heard.
    func play() async throws {
        let state = try await state()
        try #require(state.volume <= MediaTestBed.inaudible, "The bed's page would be heard at volume \(state.volume)")
        try await run("await bed.play()")
    }

    /// Pauses, and returns once it has.
    func pause() async throws { try await run("await bed.pause()") }

    /// Moves to `seconds` of media time, and returns once there.
    func seek(to seconds: Double) async throws { try await run("await bed.seek(\(seconds))") }

    /// Runs `script` in the page as a test's own action, marked `name` in the
    /// clock as it starts; `media` is the element, `bed` the page's helper.
    func run(_ script: String, mark name: String) async throws {
        try await run("bed.mark(\(String(reflecting: name))); \(script)")
    }

    /// The clock from a quarter of a second of media played before `action`
    /// to half a second played after it: an action that leaves the media
    /// paused leaves this waiting until it fails.
    func clock(around action: () async throws -> Void, before: Double = 0.25, after: Double = 0.5) async throws -> MediaClock {
        struct Start: Decodable { var samples: Int; var marks: Int; var media: Double }
        let start: Start = try await read("({ samples: bed.samples.length, marks: bed.marks.length, media: media.currentTime })")
        try await played(beyond: start.media + before, "before the action")
        try await action()
        try await played(beyond: try await state().media + after, "after the action")
        struct Taken: Decodable { var samples: [MediaClock.Sample]; var marks: [MediaClock.Mark] }
        let taken: Taken = try await read("({ samples: bed.samples.slice(\(start.samples)), marks: bed.marks.slice(\(start.marks)) })")
        return MediaClock(samples: taken.samples, marks: taken.marks)
    }

    private func played(beyond media: Double, _ when: String) async throws {
        var last: State?
        try await waitFor("The media never played to \(media) s \(when); it was \(String(describing: last))") {
            last = try await state()
            return last.map { !$0.paused && $0.media >= media } ?? false
        }
    }

    private func run(_ script: String) async throws {
        _ = try await tab.webView.callAsyncJavaScript(script, in: frame, contentWorld: .page)
    }

    /// The JSON `expression` comes to in the page, decoded.
    private func read<Value: Decodable>(_ expression: String) async throws -> Value {
        let json = try await tab.webView.callAsyncJavaScript("return JSON.stringify(\(expression))", in: frame, contentWorld: .page)
        return try JSONDecoder().decode(Value.self, from: Data(try #require(json as? String).utf8))
    }

    /// The first frame in `page`, through WebKit SPI (`_frames:`), which
    /// tests may use: nil until it has one.
    static func firstFrame(in page: WKWebView) async -> WKFrameInfo? {
        let frames = NSSelectorFromString("_frames:")
        guard page.responds(to: frames) else { return nil }
        typealias Frames = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSObject?) -> Void) -> Void
        return await withCheckedContinuation { (done: CheckedContinuation<WKFrameInfo?, Never>) in
            unsafeBitCast(page.method(for: frames), to: Frames.self)(page, frames) { tree in
                let children = tree?.value(forKey: "childFrames") as? [NSObject] ?? []
                done.resume(returning: children.first?.value(forKey: "info") as? WKFrameInfo)
            }
        }
    }

    /// A page with nothing in it but `url` in a frame, at a player's usual
    /// embedded size, allowed to float.
    static func embedding(_ url: URL) -> String {
        """
            <!doctype html>
            <meta charset="utf-8">
            <title>A bed page in a frame</title>
            <style>html, body { margin: 0; background: #222 } iframe { border: 0; display: block }</style>
            <iframe src=\(String(reflecting: url.absoluteString)) width="560" height="315" allow="autoplay; picture-in-picture"></iframe>
            """
    }

    /// Where the page's `<video>` gets its media.
    enum Source {
        case src(URL)
    }

    /// The page: the element at the bed's volume before it has a source, its
    /// helper (`bed`) and the source attached.
    static func html(source: Source) -> String {
        let attach = switch source {
        case .src(let url): "media.src = \(String(reflecting: url.absoluteString));"
        }
        return """
            <!doctype html>
            <meta charset="utf-8">
            <title>Media test bed</title>
            <style>html, body { margin: 0; height: 100%; background: #000 } video { width: 100%; height: 100% }</style>
            <video preload="auto" playsinline></video>
            <script>
            const media = document.querySelector('video');
            media.volume = \(MediaTestBed.inaudible);
            const now = () => performance.now() / 1000;
            const bed = window.bed = {
                samples: [],
                marks: [],
                sample(event) {
                    bed.samples.push({ wall: now(), media: media.currentTime, paused: media.paused, rate: media.playbackRate, event });
                },
                mark(name) { bed.marks.push({ wall: now(), name }); },
                event(name) { return new Promise(resolve => media.addEventListener(name, resolve, { once: true })); },
                async play() { bed.mark('play'); await media.play(); },
                async pause() {
                    bed.mark('pause');
                    if (media.paused) return;
                    const paused = bed.event('pause');
                    media.pause();
                    await paused;
                },
                async seek(to) {
                    bed.mark('seek');
                    const seeked = bed.event('seeked');
                    media.currentTime = to;
                    await seeked;
                },
                state() {
                    return {
                        media: media.currentTime, paused: media.paused, rate: media.playbackRate,
                        volume: media.volume, muted: media.muted, readyState: media.readyState,
                        videoWidth: media.videoWidth, videoHeight: media.videoHeight,
                        hasSound: media.audioTracks.length > 0,
                    };
                },
            };
            for (const name of ['play', 'playing', 'pause', 'seeking', 'seeked', 'ratechange', 'waiting', 'stalled', 'timeupdate', 'ended'])
                media.addEventListener(name, () => bed.sample(name));
            // No requestVideoFrameCallback: watching frames has WebKit report
            // media time frame by frame, which a page playing a video doesn't.
            setInterval(() => bed.sample('tick'), 20);
            \(attach)
            </script>
            """
    }
}
