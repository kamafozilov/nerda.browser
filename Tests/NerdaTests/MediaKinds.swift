import Testing
import AppKit
import Foundation
import WebKit
@testable import Nerda
import MediaCheck

// The kinds of media the bed gives out besides a file (`BedMedia`), each
// generated as the test runs: a Media Source stream, an HLS stream and a
// live stream whose page nudges its speed towards the live edge.

extension GeneratedMovie {
    /// Generated once per run for each length and sound: the same bytes
    /// every time, and a second or more each to make.
    @MainActor private static var made: [String: Task<GeneratedSegments, any Error>] = [:]

    @MainActor
    static func cachedSegments(seconds: Double, sound: GeneratedSound) async throws -> GeneratedSegments {
        let key = "\(seconds) \(sound)"
        if let made = made[key] { return try await made.value }
        let making = Task { try await segments(seconds: seconds, sound: sound) }
        made[key] = making
        return try await making.value
    }
}

extension MediaPage {
    /// A stream's segments as the bed serves them: where each is, and when.
    struct Stream: Encodable {
        struct Piece: Encodable {
            var url: URL
            var start: Double
            var duration: Double
        }

        /// The Media Source type: `video/mp4; codecs="avc1.42000D,mp4a.40.2"`.
        var type: String
        var initialization: URL
        var segments: [Piece]
        /// Where the picture's first frame is in the segments' own time: the
        /// writer moves it on by the sound encoder's priming.
        var offset: Double
    }

    /// A script function that opens a `MediaSource` on the element for a
    /// stream, its buffer moved back by `offset`, so its first frame is at 0
    /// as a file's is, and answers it with `append(url)`, which fetches a
    /// segment and appends it.
    private static let opening = """
        (async stream => {
            const source = new MediaSource();
            media.src = URL.createObjectURL(source);
            await new Promise(resolve => source.addEventListener('sourceopen', resolve, { once: true }));
            const buffer = source.addSourceBuffer(stream.type);
            buffer.timestampOffset = -stream.offset;
            const append = async url => {
                const data = await (await fetch(url)).arrayBuffer();
                await new Promise((resolve, reject) => {
                    buffer.addEventListener('updateend', resolve, { once: true });
                    buffer.addEventListener('error', () => reject(new Error('append failed: ' + url)), { once: true });
                    buffer.appendBuffer(data);
                });
            };
            return { source, append };
        })
        """

    /// Fetches the stream's segments and appends them, all of them, to a
    /// `MediaSource` (`opening`). `bed.stream` tells how far it got, and any error.
    static func mediaSourceScript(_ stream: Stream) -> String {
        """
        bed.stream = { appended: 0, error: null };
        (async () => {
            const stream = \(json(stream));
            const { source, append } = await \(opening)(stream);
            await append(stream.initialization);
            for (const piece of stream.segments) {
                await append(piece.url);
                bed.stream.appended += 1;
            }
            source.endOfStream();
        })().catch(error => { bed.stream.error = String(error); });
        """
    }

    /// How the live page plays: as a live player keeps close to its edge.
    /// The broadcast runs a little fast against the page's clock, as an
    /// encoder's clock does against another's, only more, so the page falls
    /// behind every few seconds, not every few minutes: then it plays at
    /// `nudge` until it is back at `target` behind the edge, and at 1 again.
    /// In WebKit each change of speed also holds the media still for
    /// 0.1–0.5 s (measured 2026-11-27), which puts the page behind again as
    /// it comes back to 1: it nudges on and off without end, one round in
    /// some 4 s.
    enum Live {
        /// How far behind the edge the page keeps, in seconds of media: two
        /// whole segments ahead of it or more, so a page kept busy still has
        /// them appended in time.
        static let target = 3.0
        /// How much further behind it falls before it catches up.
        static let band = 0.02
        /// The speed it catches up at: within 0.1 of 1, as live players use.
        static let nudge = 1.09
        /// How fast the edge moves on against the wall clock.
        static let skew = 1.01
    }

    /// A live stream from `stream`'s segments: each appended once the edge
    /// has passed its end, the edge starting `Live.target` and a bit ahead
    /// of the start, so the first nudge comes at once, and moving on from
    /// when media time first moves. `bed.live` tells the edge, the
    /// latency, and each nudge (also marked in the clock: `nudge to 1.08`).
    static func liveScript(_ stream: Stream) -> String {
        """
        bed.live = { nudges: [], error: null };
        (async () => {
            const stream = \(json(stream));
            const live = { target: \(Live.target), band: \(Live.band), nudge: \(Live.nudge), skew: \(Live.skew) };
            const { source, append } = await \(opening)(stream);
            const first = live.target + live.band + 0.01;
            // From when media time first moves: a stream starts playing a
            // moment after it says it plays.
            let begun = null;
            const begin = () => { if (begun === null && media.currentTime > 0.05) { begun = now() - media.currentTime / live.skew; bed.live.begun = [now(), media.currentTime, begun]; } };
            media.addEventListener('timeupdate', begin);
            bed.live.edge = () => first + (begun === null ? 0 : (now() - begun) * live.skew);
            bed.live.latency = () => bed.live.edge() - media.currentTime;
            let next = 0, publishing = false;
            const publish = async () => {
                if (publishing) return;
                publishing = true;
                try {
                    while (next < stream.segments.length) {
                        const piece = stream.segments[next];
                        if (piece.start - stream.offset + piece.duration > bed.live.edge()) break;
                        await append(piece.url);
                        next += 1;
                    }
                } finally { publishing = false; }
            };
            await append(stream.initialization);
            await publish();
            let catchingUp = false;
            const speed = rate => {
                media.playbackRate = rate;
                bed.live.nudges.push({ wall: now(), rate });
                bed.mark('nudge to ' + rate);
            };
            setInterval(() => {
                begin();
                publish().catch(error => { bed.live.error = String(error); });
                if (media.paused) return;
                const latency = bed.live.latency();
                if (!catchingUp && latency > live.target + live.band) { catchingUp = true; speed(live.nudge); }
                else if (catchingUp && latency <= live.target) { catchingUp = false; speed(1); }
            }, 100);
        })().catch(error => { bed.live.error = String(error); });
        """
    }

    /// Returns once the live page has nudged its speed off 1 and back to 1
    /// again, from now on: in up to two rounds of `Live`'s.
    func nudged() async throws {
        let from: Int = try await read("bed.live.nudges.length")
        var nudges: [Double] = [], latency = 0.0, ahead = 0.0, state: State?
        try await waitFor("The live page never nudged its speed off 1 and back; it nudged \(nudges), \(latency) s behind, \(ahead) s buffered ahead, \(String(describing: state))",
                          timeout: .seconds(15)) {
            nudges = try await read("bed.live.nudges.slice(\(from)).map(n => n.rate)")
            latency = try await read("bed.live.latency()")
            ahead = try await read("media.buffered.length ? media.buffered.end(media.buffered.length - 1) - media.currentTime : 0")
            state = try await self.state()
            guard let off = nudges.firstIndex(where: { $0 != 1 }) else { return false }
            return nudges[off...].contains(1)
        }
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}

extension MediaTestBed {
    /// Serves `movie`'s segments under `path`: `init.mp4`, then `0.m4s`,
    /// `1.m4s`… as fragmented MP4.
    func serve(_ movie: GeneratedSegments, at path: String) async throws -> MediaPage.Stream {
        let initialization = try await server.serve("\(path)/init.mp4", movie.initialization, type: "video/mp4")
        var pieces: [MediaPage.Stream.Piece] = []
        for (index, segment) in movie.media.enumerated() {
            let url = try await server.serve("\(path)/\(index).m4s", segment.data, type: "video/iso.segment")
            pieces.append(.init(url: url, start: segment.start, duration: segment.duration))
        }
        return MediaPage.Stream(type: "video/mp4; codecs=\"\(movie.codecs)\"", initialization: initialization,
                                segments: pieces, offset: movie.media.first?.start ?? 0)
    }

    /// Serves `movie` as an HLS stream under `path`, its playlist
    /// `index.m3u8` listing the segments `serve(_:at:)` gives out, and
    /// answers the playlist's address.
    func servePlaylist(_ movie: GeneratedSegments, at path: String) async throws -> URL {
        _ = try await serve(movie, at: path)
        let longest = movie.media.map(\.duration).max() ?? 1
        let lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"init.mp4\""]
            + movie.media.enumerated().flatMap { index, segment in [String(format: "#EXTINF:%.3f,", segment.duration), "\(index).m4s"] }
            + ["#EXT-X-ENDLIST"]
        return try await server.serve("\(path)/index.m3u8", Data((lines.joined(separator: "\n") + "\n").utf8),
                                      type: "application/vnd.apple.mpegurl")
    }

    /// `media` in a bare `WKWebView`: nothing of Nerda's in it (its scripts,
    /// its settings, its tab), in a plain window of its own behind the
    /// others, playing the same page `open` gives a tab. What it does too is
    /// WebKit's, not Nerda's.
    func playBare(_ media: BedMedia) async throws -> MediaPage {
        nextPage()
        let source = try await serve(media, as: "/media/\(pages)")
        let url = try await server.serve("/page/\(pages)", html: MediaPage.html(source: source))
        let bare = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        let webView = WKWebView(frame: bare.contentLayoutRect)
        webView.hearsWindowCovered(false)
        bare.contentView = webView
        bare.orderBack(nil)
        windows.append(bare)
        webView.load(URLRequest(url: url))
        let page = MediaPage(webView: webView)
        try await waitFor("The bare page never loaded with its media") {
            guard webView.url == url, !webView.isLoading else { return false }
            return try await page.state().readyState >= 1
        }
        try await page.play()
        return page
    }
}
