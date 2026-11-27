import Foundation
import Testing
@testable import Nerda

/// Every kind of media the bed gives out, and every action the owner takes
/// on a video: the page's media clock runs on without a jump or a stall,
/// and the picture shown is the media time's afterwards. Serialized, as
/// every suite that really plays media is.
@Suite(.serialized)
@MainActor
struct MediaActionsTests {
    /// The media, and for live, with Nerda's live-speed handling on and off.
    enum Kind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case file, mediaSource, hls, live, liveWithoutLiveRate

        var media: BedMedia {
            switch self {
            case .file: .file()
            case .mediaSource: .mediaSource()
            case .hls: .hls()
            case .live, .liveWithoutLiveRate: .live()
            }
        }

        var isLive: Bool { self == .live || self == .liveWithoutLiveRate }
        var isMediaSource: Bool { self == .mediaSource || isLive }
        var liveRate: Bool { self != .liveWithoutLiveRate }
        var testDescription: String { rawValue }
    }

    /// The clock around `action` on a page playing `kind`, from a second
    /// into the media (a start has stalls of its own), for live once its
    /// page has nudged its speed and Nerda's handling (`LiveRate`) is at
    /// work; and the picture after.
    private func around(_ kind: Kind, alone: Bool = false,
                        _ action: (MediaTestBed, MediaPage) async throws -> Void) async throws -> (MediaClock, MediaPage.Picture) {
        let bed = try await MediaTestBed(liveRate: kind.liveRate, alone: alone)
        defer { bed.close() }
        let page = try await bed.play(kind.media)
        try await page.played(beyond: 1, "before the check")
        if kind.isLive { try await page.nudged() }
        var clock = try await page.clock(around: { try await action(bed, page) })
        // A nudge just before the clock starts can hold the media within it.
        if kind.isLive, let first = clock.samples.first?.wall {
            let nudges: [MediaClock.Mark] = try await page.read("bed.marks.filter(mark => mark.name.startsWith('nudge'))")
            clock.marks = nudges.filter { $0.wall < first && $0.wall >= first - 1 } + clock.marks
        }
        return (clock, try await page.picture())
    }

    /// What every check asks of the clock and the picture: no jump, no
    /// stall, picture and media time in step. Save what WebKit does itself,
    /// the same in a bare `WKWebView` with nothing of Nerda's (measured
    /// 2026-11-27, numbers on #157), kept here as known issues, so a check
    /// still fails on anything else and tells once WebKit stops:
    ///
    /// - At each change of speed, the page's or Nerda's (`LiveRate`'s
    ///   1.0001), media stands still 0.05–0.5 s, the picture with it, on
    ///   every kind; on AVPlayer (a file, HLS) media time can go back too.
    ///   `speedEveryTime`: the check itself changes speed, and WebKit's
    ///   hold has always shown.
    /// - After a seek, media plays 50–140 ms, then stands still 0.05–0.3 s:
    ///   always on AVPlayer, now and then in Media Source (`restart`). The
    ///   same once on HLS as it played again at the wake notice (67–91 ms,
    ///   in one full run of three; none in 24 rounds bare or in Nerda).
    /// - Just after a change of speed, the picture of a Media Source stream
    ///   can be up to 0.15 s behind its media time, for under a second.
    /// - Paused, media time can stand ahead of the picture on show, WebKit's
    ///   estimate run on to its cap, and played again, media goes on from
    ///   the picture: a jump back to the frame that was on show (`still`;
    ///   measured by #161 with the page busy 70 ms in every 100).
    private func expectSmooth(_ clock: MediaClock, _ picture: MediaPage.Picture?, _ kind: Kind, speedEveryTime: Bool = false,
                              restart: (wall: Double, everyTime: Bool)? = nil, still: MediaPage.Still? = nil,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let stalls = clock.stalls(over: MediaClock.tolerance)
        var jumps = clock.jumps(over: MediaClock.tolerance)
        // Back to the frame that was on show at the pause, from an estimate ahead of it.
        let frame = 1 / Double(GeneratedMovie.framesPerSecond)
        let toStill = jumps.filter { jump in
            guard let still, let ahead = still.ahead, ahead > 2 * frame, jump.by < 0, jump.after == "play" else { return false }
            return abs(jump.media + jump.by - (still.current - ahead)) <= 2 * frame
        }
        jumps.removeAll { toStill.contains($0) }
        if !toStill.isEmpty {
            withKnownIssue("WebKit's picture behind media time at the pause", isIntermittent: true) {
                Issue.record("\(toStill), \(String(describing: still))", sourceLocation: sourceLocation)
            }
        }
        let speeds = clock.marks.filter { $0.name.hasPrefix("speed") || $0.name.hasPrefix("nudge") }
        let atSpeed = { (wall: Double) in speeds.contains { wall >= $0.wall - 0.05 && wall <= $0.wall + 0.6 } }
        let afterSeek = { (wall: Double) in restart.map { wall >= $0.wall && wall <= $0.wall + 1 } ?? false }
        let speedJumps = jumps.filter { atSpeed($0.wall) }, speedStalls = stalls.filter { atSpeed($0.wall) }
        let seekStalls = stalls.filter { !atSpeed($0.wall) && afterSeek($0.wall) }
        let otherJumps = jumps.filter { !atSpeed($0.wall) }, otherStalls = stalls.filter { !atSpeed($0.wall) && !afterSeek($0.wall) }
        #expect(otherJumps.isEmpty, "\(otherJumps)", sourceLocation: sourceLocation)
        #expect(otherStalls.isEmpty, "\(otherStalls)", sourceLocation: sourceLocation)
        if !speeds.isEmpty {
            withKnownIssue("WebKit holds media still at each change of speed", isIntermittent: !speedEveryTime) {
                #expect(speedStalls.isEmpty && speedJumps.isEmpty, "\(speedStalls) \(speedJumps)", sourceLocation: sourceLocation)
            }
        }
        if let restart {
            withKnownIssue("WebKit holds media still a moment after it starts again", isIntermittent: !restart.everyTime) {
                #expect(seekStalls.isEmpty, "\(seekStalls)", sourceLocation: sourceLocation)
            }
        }
        guard let picture else { return }
        let apart = picture.apart
        #expect(apart != nil, "The picture couldn't be read: \(picture)", sourceLocation: sourceLocation)
        guard let apart, abs(apart) > Self.inStep else { return }
        if kind.isMediaSource, !speeds.isEmpty, abs(apart) <= Self.behindAfterSpeed {
            withKnownIssue("WebKit's Media Source picture lags after a change of speed") {
                Issue.record("\(picture)", sourceLocation: sourceLocation)
            }
        } else {
            Issue.record("Picture and media time apart: \(picture)", sourceLocation: sourceLocation)
        }
    }

    /// How far picture and media time may be apart: two frames.
    static let inStep = 2.0 / Double(GeneratedMovie.framesPerSecond)
    /// How far behind a Media Source picture has been seen just after a
    /// change of speed, in a bare `WKWebView` as in Nerda (measured
    /// 2026-11-27: 100–143 ms, back within two frames a second later).
    static let behindAfterSpeed = 0.2
    /// How far behind media time the picture has been seen paused.
    static let behindPaused = 0.3

    @Test(arguments: Kind.allCases)
    func pausingASecondAndPlayingCarriesOnWhereItStopped(_ kind: Kind) async throws {
        var still: MediaPage.Still?
        let (clock, picture) = try await around(kind) { _, page in still = try await page.pause(for: 1) }
        // Paused, the picture on show is the media time's.
        let ahead = try #require(still?.ahead, "The picture couldn't be read paused: \(String(describing: still))")
        // Behind it as WebKit's picture is, by #161's estimate run ahead (0.1 s),
        // or just after a change of speed on Media Source (live paused at
        // 148–163 ms, measured 2026-11-27, `behindAfterSpeed`).
        if ahead > Self.inStep, ahead <= Self.behindPaused {
            withKnownIssue("WebKit's picture behind media time at the pause", isIntermittent: true) {
                Issue.record("\(String(describing: still))")
            }
        } else {
            #expect(abs(ahead) <= Self.inStep, "Picture and media time apart at the pause: \(String(describing: still))")
        }
        expectSmooth(clock, picture, kind, still: still)
    }

    /// Jumps once, to where it was asked to, and plays on from there.
    @Test(arguments: Kind.allCases)
    func seekingPlaysOnFromTheNewPlace(_ kind: Kind) async throws {
        // Live seeks back, within what it has; the others on.
        let by = kind.isLive ? -1.0 : 3.0
        var target = 0.0
        let (clock, picture) = try await around(kind) { _, page in
            target = try await page.state().media + by
            try await page.seek(to: target)
        }
        let seek = try #require(clock.marks.last { $0.name == "seek" }).wall
        let seeked = try #require(clock.samples.first { $0.wall >= seek && $0.event == "seeked" })
        #expect(abs(seeked.media - target) < MediaClock.tolerance)
        // Taken apart at the seek: its own jump is what was asked.
        let before = MediaClock(samples: clock.samples.filter { $0.wall < seek }, marks: clock.marks)
        let after = MediaClock(samples: clock.samples.filter { $0.wall >= seeked.wall }, marks: clock.marks)
        expectSmooth(before, nil, kind)
        expectSmooth(after, picture, kind, restart: (seek, everyTime: !kind.isMediaSource))
    }

    /// At 1.5 for half a second, then 1 again; live changes its own speed,
    /// off 1 and back, as it catches up with its edge.
    @Test(arguments: Kind.allCases)
    func changingSpeedKeepsPlaying(_ kind: Kind) async throws {
        let (clock, picture) = try await around(kind) { _, page in
            if kind.isLive { try await page.nudged() } else { try await page.changeSpeed(to: 1.5) }
        }
        expectSmooth(clock, picture, kind, speedEveryTime: true)
    }

    @Test(arguments: Kind.allCases)
    func fullScreenInAndOutKeepsPlaying(_ kind: Kind) async throws {
        var visible = "", element = "", asks = 0, windowFullScreen = true
        let (clock, picture) = try await around(kind) { bed, page in
            try await bed.enterFullScreen(page)
            element = try await page.read("document.fullscreenElement?.tagName ?? ''")
            try await waitFor("Nerda never asked the window to go full screen with the page") {
                asks = (bed.window as? BedWindow)?.fullScreenAsks ?? 0
                return asks > 0
            }
            try await page.played(beyond: try await page.state().media + 0.5, "in full screen")
            try await bed.leaveFullScreen(page)
            visible = try await page.read("document.visibilityState")
            windowFullScreen = bed.window.styleMask.contains(.fullScreen)
        }
        // The page's full screen, Nerda asking the window to follow, which
        // the bed's never does.
        #expect(element == "VIDEO")
        #expect(asks == 1)
        #expect(!windowFullScreen)
        #expect(visible == "visible")
        expectSmooth(clock, picture, kind)
    }

    /// A second out of sight behind another tab, playing all the while.
    @Test(arguments: Kind.allCases)
    func leavingTheTabAndComingBackKeepsPlaying(_ kind: Kind) async throws {
        let (clock, picture) = try await around(kind) { bed, page in try await bed.leaveAndReturn(page) }
        expectSmooth(clock, picture, kind)
    }

    /// Paused as the Mac goes to sleep, playing again from there as it
    /// wakes. Alone: the notice reaches every page of the run.
    @Test(arguments: Kind.allCases)
    func sleepingAndWakingCarriesOnWhereItStopped(_ kind: Kind) async throws {
        let (clock, picture) = try await around(kind, alone: true) { bed, page in try await bed.sleepAndWake(page) }
        let sleep = try #require(clock.marks.first { $0.name == "sleep" }).wall
        let wake = try #require(clock.marks.first { $0.name == "wake" }).wall
        #expect(clock.samples.contains { $0.wall > sleep && $0.wall < wake && $0.paused })
        // Playing again at the wake is a start: on AVPlayer, WebKit's hold after one.
        let restart: (wall: Double, everyTime: Bool)? = kind.isMediaSource ? nil : (wake, false)
        expectSmooth(clock, picture, kind, restart: restart)
    }
}
