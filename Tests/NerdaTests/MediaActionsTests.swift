import Foundation
import Testing
@testable import Nerda
import MediaCheck

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
    /// work; and the picture after. `action` is given the bed, the page,
    /// and for live how many nudges the page had made as the clock started.
    ///
    /// Live from where `nudged()` returns, as the page comes back to 1 at
    /// the end of its second round (some 13 s in), not the next time it
    /// does: started at the end of its first (7–9 s in), WebKit held media
    /// 70–125 ms just after it played again at the wake (both live kinds,
    /// in the one run started there) and as the tab was shown again (both,
    /// in 1 run of 5), measured 2026-11-27.
    private func around(_ kind: Kind, alone: Bool = false,
                        _ action: (MediaTestBed, MediaPage, _ nudges: Int) async throws -> Void) async throws -> (MediaClock, MediaPage.Picture) {
        let bed = try await MediaTestBed(liveRate: kind.liveRate, alone: alone)
        defer { bed.close() }
        let page = try await bed.play(kind.media)
        try await page.played(beyond: 1, "before the check")
        if kind.isLive { try await page.nudged() }
        let nudges: Int = kind.isLive ? try await page.read("bed.live.nudges.length") : 0
        var clock = try await page.clock(around: { try await action(bed, page, nudges) })
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
    ///   every kind, and stepping up, often once more 0.3–0.9 s later
    ///   (60–145 ms); on AVPlayer (a file, HLS) media time can go back too.
    ///   `speedEveryTime`: the check itself changes speed, and WebKit's
    ///   hold has always shown.
    /// - After a seek, media plays 50–140 ms from where it lands, then
    ///   stands still 0.05–0.3 s: on AVPlayer always on a quiet Mac, and
    ///   in 5 of 16 rounds with four other beds' media beside it (Nerda 2 of
    ///   8, bare 3 of 8: the seek itself took up to 1.25 s then, and the
    ///   page's sampling missed the hold or there was none); now and then in
    ///   Media Source (`restart`, from where it lands), there
    ///   after a pause too (live: 77–82 ms, bare `WKWebView` too). The
    ///   same once on HLS as it played again at the wake notice (67–91 ms,
    ///   in one full run of three; none in 24 rounds bare or in Nerda).
    /// - Just after a change of speed, the picture of a Media Source stream
    ///   can be up to 0.15 s behind its media time, for under a second.
    /// - Paused, media time can stand ahead of the picture on show, WebKit's
    ///   estimate run on to its cap, and played again, media goes on from
    ///   the picture: a jump back to the frame that was on show (`still`;
    ///   measured by #161 with the page busy 70 ms in every 100).
    /// - A live Media Source stream shown again after a second behind
    ///   another tab: as the page appends its next segment, media stands
    ///   still 0.09–0.15 s, 0.05–0.36 s after the tab is back, in about a
    ///   quarter of rounds, bare `WKWebView` the same; a stream with all of
    ///   it appended doesn't (`restart`, `restartLost`).
    /// - Paused while other pages' media keeps WebKit busy, media can stop
    ///   later than media time says, which holds where the pause was asked
    ///   while the picture goes on 1–12 frames; played again, media time
    ///   comes to the frame on show: a jump forward (`Paused.late`).
    private func expectSmooth(_ clock: MediaClock, _ picture: MediaPage.Picture?, _ kind: Kind, speedEveryTime: Bool = false,
                              restart: (wall: Double, everyTime: Bool)? = nil,
                              restartWhy: Comment = "WebKit holds media still a moment after it starts again",
                              restartLost: Double = .infinity, paused: MediaPage.Paused? = nil,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let stalls = clock.stalls(over: MediaClock.tolerance)
        var jumps = clock.jumps(over: MediaClock.tolerance)
        // On to the frame on show as the pause ended, from a pause WebKit made late.
        let late = paused?.late(jumps, in: clock) ?? []
        jumps.removeAll { late.contains($0) }
        if !late.isEmpty {
            withKnownIssue("WebKit pauses later than its media time says", isIntermittent: true) {
                Issue.record("\(late), \(String(describing: paused))", sourceLocation: sourceLocation)
            }
        }
        // Back to the frame that was on show at the pause, from an estimate ahead of it.
        let still = paused?.still
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
        // WebKit's holds come at the change and, stepping up, once more up to
        // 0.9 s after it (measured in a bare `WKWebView` too).
        let atSpeed = { (wall: Double) in speeds.contains { wall >= $0.wall - 0.05 && wall <= $0.wall + 1 } }
        let afterSeek = { (stall: MediaClock.Stall) in
            restart.map { stall.wall >= $0.wall && stall.wall <= $0.wall + 1 && stall.lost <= restartLost } ?? false
        }
        let speedJumps = jumps.filter { atSpeed($0.wall) }, speedStalls = stalls.filter { atSpeed($0.wall) }
        let seekStalls = stalls.filter { !atSpeed($0.wall) && afterSeek($0) }
        let otherJumps = jumps.filter { !atSpeed($0.wall) }, otherStalls = stalls.filter { !atSpeed($0.wall) && !afterSeek($0) }
        // A failing one shows the whole timeline, so it can be judged after.
        #expect(otherJumps.isEmpty, "\(otherJumps)\n\(paused.map { "\($0)\n" } ?? "")\(clock.record)", sourceLocation: sourceLocation)
        #expect(otherStalls.isEmpty, "\(otherStalls)\n\(clock.record)", sourceLocation: sourceLocation)
        if !speeds.isEmpty {
            withKnownIssue("WebKit holds media still at each change of speed", isIntermittent: !speedEveryTime) {
                #expect(speedStalls.isEmpty && speedJumps.isEmpty, "\(speedStalls) \(speedJumps)", sourceLocation: sourceLocation)
            }
        }
        if let restart {
            withKnownIssue(restartWhy, isIntermittent: !restart.everyTime) {
                #expect(seekStalls.isEmpty, "\(seekStalls)\n\(clock.record)", sourceLocation: sourceLocation)
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
    /// How long WebKit has been seen to hold a live stream shown again, in
    /// a bare `WKWebView` as in Nerda: 0.094–0.142 s (measured 2026-11-27).
    static let heldAfterReturn = 0.2

    @Test(arguments: Kind.allCases)
    func pausingASecondAndPlayingCarriesOnWhereItStopped(_ kind: Kind) async throws {
        var paused: MediaPage.Paused?
        let (clock, picture) = try await around(kind) { _, page, _ in paused = try await page.pause(for: 1) }
        let still = paused?.still
        // Paused, the picture on show is the media time's.
        let ahead = try #require(still?.ahead, "The picture couldn't be read paused: \(String(describing: still))")
        // Behind it as WebKit's picture is, by #161's estimate run ahead (0.1 s),
        // or just after a change of speed on Media Source (live paused at
        // 148–163 ms, measured 2026-11-27, `behindAfterSpeed`).
        if ahead > Self.inStep, ahead <= Self.behindPaused {
            withKnownIssue("WebKit's picture behind media time at the pause", isIntermittent: true) {
                Issue.record("\(String(describing: still))")
            }
        } else if ahead < -Self.inStep, let paused, paused.isLate {
            // Ahead of it, a pause WebKit made late (`Paused.late`).
            withKnownIssue("WebKit pauses later than its media time says", isIntermittent: true) {
                Issue.record("\(paused)")
            }
        } else {
            #expect(abs(ahead) <= Self.inStep, "Picture and media time apart at the pause: \(String(describing: still))")
        }
        // Playing again is a start: on Media Source, now and then WebKit's
        // hold after one (77 ms 0.18 s after play in a bare `WKWebView`).
        let play = clock.marks.last { $0.name == "play" }?.wall
        let restart: (wall: Double, everyTime: Bool)? = kind.isMediaSource ? play.map { ($0, false) } : nil
        expectSmooth(clock, picture, kind, restart: restart, paused: paused)
    }

    /// Jumps once, to where it was asked to, and plays on from there.
    @Test(arguments: Kind.allCases)
    func seekingPlaysOnFromTheNewPlace(_ kind: Kind) async throws {
        // Live seeks back, within what it has; the others on.
        let by = kind.isLive ? -1.0 : 3.0
        var target = 0.0
        let (clock, picture) = try await around(kind) { _, page, _ in
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
        // From where it lands: a busy WebKit can take over a second to seek.
        expectSmooth(after, picture, kind, restart: (seeked.wall, everyTime: false))
    }

    /// At 1.5 for half a second, then 1 again; live changes its own speed,
    /// off 1 and back, as it catches up with its edge, both within the
    /// clock: the clock starts as it comes back to 1, so it goes off 1
    /// again at once, while the clock reads its first quarter second.
    @Test(arguments: Kind.allCases)
    func changingSpeedKeepsPlaying(_ kind: Kind) async throws {
        let (clock, picture) = try await around(kind) { _, page, nudges in
            if kind.isLive { try await page.nudged(since: nudges) } else { try await page.changeSpeed(to: 1.5) }
        }
        expectSmooth(clock, picture, kind, speedEveryTime: true)
    }

    @Test(arguments: Kind.allCases)
    func fullScreenInAndOutKeepsPlaying(_ kind: Kind) async throws {
        var visible = "", element = "", asks = 0, windowFullScreen = true
        let (clock, picture) = try await around(kind) { bed, page, _ in
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
        let (clock, picture) = try await around(kind) { bed, page, _ in try await bed.leaveAndReturn(page) }
        // Live: WebKit's hold at the first segment appended once back.
        let back = clock.marks.last { $0.name == "return" }?.wall
        let restart: (wall: Double, everyTime: Bool)? = kind.isLive ? back.map { ($0, false) } : nil
        expectSmooth(clock, picture, kind, restart: restart,
                     restartWhy: "WebKit holds a live stream still as it appends once its page is shown again",
                     restartLost: Self.heldAfterReturn)
    }

    /// Paused as the Mac goes to sleep, playing again from there as it
    /// wakes. Alone: the notice reaches every page of the run.
    @Test(arguments: Kind.allCases)
    func sleepingAndWakingCarriesOnWhereItStopped(_ kind: Kind) async throws {
        let (clock, picture) = try await around(kind, alone: true) { bed, page, _ in try await bed.sleepAndWake(page) }
        let sleep = try #require(clock.marks.first { $0.name == "sleep" }).wall
        let wake = try #require(clock.marks.first { $0.name == "wake" }).wall
        #expect(clock.samples.contains { $0.wall > sleep && $0.wall < wake && $0.paused })
        // Playing again at the wake is a start: on AVPlayer, WebKit's hold after one.
        let restart: (wall: Double, everyTime: Bool)? = kind.isMediaSource ? nil : (wake, false)
        expectSmooth(clock, picture, kind, restart: restart)
    }
}
