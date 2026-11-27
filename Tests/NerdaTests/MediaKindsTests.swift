import Foundation
import Testing
@testable import Nerda

/// The kinds of media the test bed gives out besides a file (`BedMedia`):
/// a Media Source stream, an HLS stream and a live stream, each made as the
/// test runs from fragmented MP4 segments (`GeneratedMovie.segments`).
struct GeneratedSegmentsTests {
    /// What a player fetches bit by bit: an initialization segment, then
    /// one media segment per second, together as long as the movie asked for.
    @Test func aMovieComesInSegmentsOfASecond() async throws {
        let movie = try await GeneratedMovie.segments(seconds: 4, sound: .tone(hertz: 440))
        #expect(String(decoding: movie.initialization.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp")
        #expect(movie.media.count == 4)
        for segment in movie.media {
            #expect(abs(segment.duration - 1) < 0.05)
            #expect(["styp", "moof"].contains(String(decoding: segment.data.dropFirst(4).prefix(4), as: UTF8.self)))
        }
        #expect(abs(movie.media.map(\.duration).reduce(0, +) - 4) < 0.05)
        #expect(movie.codecs.hasPrefix("avc1.") && movie.codecs.hasSuffix(",mp4a.40.2"))
    }
}

/// Each kind plays in the bed, its media really fetched from the bed's server.
@Suite(.serialized)
@MainActor
struct MediaKindsTests {
    @Test func aMediaSourceStreamPlaysInTheBed() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.mediaSource())
        let state = try await page.state()
        #expect(state.videoWidth == 320 && state.videoHeight == 180)
        #expect(state.hasSound)
        let clock = try await page.clock(around: {})
        #expect(try #require(clock.samples.last).media - clock.samples[0].media > 0.5)
        #expect(try await page.read("media.src.startsWith('blob:')") as Bool)
        #expect(bed.server.requests.contains { $0.hasPrefix("GET /media/1/init.mp4") })
        #expect(bed.server.requests.contains { $0.hasPrefix("GET /media/1/0.m4s") })
    }

    /// HLS as Safari plays it, the page only pointing `src` at the playlist:
    /// WebKit hands it to AVPlayer, which fetches the segments itself.
    @Test func anHLSStreamPlaysInTheBed() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.hls())
        let state = try await page.state()
        #expect(state.videoWidth == 320 && state.videoHeight == 180)
        #expect(state.hasSound)
        let clock = try await page.clock(around: {})
        #expect(try #require(clock.samples.last).media - clock.samples[0].media > 0.5)
        #expect(bed.server.requests.contains { $0.hasPrefix("GET /media/1/index.m3u8") })
        #expect(bed.server.requests.contains { $0.hasPrefix("GET /media/1/0.m4s") })
    }

    /// Nerda's live-speed handling (`LiveRate`) is on in a page unless its
    /// switch is off for the page's data store, as a test or a run turns it.
    @Test(arguments: [true, false])
    func theLiveSpeedSwitchDecidesWhetherAPageGetsItsSpeedHandled(on: Bool) async throws {
        let bed = try await MediaTestBed(liveRate: on)
        defer { bed.close() }
        let page = try await bed.open(.file())
        let native: Bool = try await page.read(
            "Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'playbackRate').get.toString().includes('[native code]')")
        #expect(native == !on)
    }

    /// A live stream: segments come as its edge moves on, and its page
    /// nudges the speed to keep close to the edge, off 1 and back, as live
    /// players do, again and again.
    @Test func aLiveStreamPlaysNearItsEdgeNudgingItsSpeed() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.live())
        let state = try await page.state()
        #expect(state.videoWidth == 320 && state.videoHeight == 180)
        #expect(state.hasSound)
        try await page.nudged()
        try await page.nudged()
        let rates: [Double] = try await page.read("bed.live.nudges.map(n => n.rate)")
        #expect(rates.starts(with: [MediaPage.Live.nudge, 1, MediaPage.Live.nudge, 1]))
        let latency: Double = try await page.read("bed.live.latency()")
        #expect(abs(latency - MediaPage.Live.target) < 0.5)
        let segments = bed.server.requests.filter { $0.hasPrefix("GET /media/1/") && $0.contains(".m4s") }
        #expect(segments.count < 15, "Fetched as the edge moved on, not all at once: \(segments.count)")
    }

    /// Nudged on and off for a minute, a live stream plays on all the
    /// while. With 1 played as 1.0001 (`LiveRate` before #162), WebKit's
    /// Media Source stopped for good within a minute, after 0.9 to 49 s.
    @Test func aLiveStreamNudgedForAMinuteKeepsPlaying() async throws {
        let bed = try await MediaTestBed()
        defer { bed.close() }
        let page = try await bed.play(.live())
        let from = try await page.state().media
        try await page.hold(60)
        let nudges: Int = try await page.read("bed.live.nudges.length")
        #expect(nudges >= 12)
        #expect(try await page.state().media - from > 55)
    }
}
