import AppKit
import Foundation
import Testing
import WebKit
@testable import Nerda

// What the owner does to a playing video, done to a bed page (`MediaPage`)
// as Nerda would have it done: pausing for a while, changing speed, full
// screen in and out, leaving the tab and coming back, the Mac sleeping and
// waking. Each marks itself in the page's clock and returns once done.

/// Who plays media in this run, for what reaches every page of it at once:
/// the system's sleep notice, which WebKit hears in the app's process and
/// pauses every page's media for (measured 2026-11-27, every kind of
/// media). Each media test bed holds the run's gate (`run`) shared; one
/// that posts such a notice holds it alone, so no other test's media is
/// paused under it. Two runs side by side don't hear each other's notices.
@MainActor
final class MediaGate {
    static let run = MediaGate()

    @MainActor final class Hold {
        private weak var gate: MediaGate?
        fileprivate let alone: Bool

        fileprivate init(_ gate: MediaGate, alone: Bool) {
            self.gate = gate
            self.alone = alone
        }

        func release() {
            gate?.released(self)
            gate = nil
        }

        isolated deinit { release() }
    }

    private var sharing = 0, single = false
    private var waiting: [(alone: Bool, go: CheckedContinuation<Void, Never>)] = []

    /// How many wait their turn.
    var waitingCount: Int { waiting.count }

    /// Held beside other shared holds, once no one holds it alone. Not
    /// kept waiting for one who only waits to hold it alone: a test holding
    /// a bed may make another, and would wait on itself.
    func shared() async -> Hold { await take(alone: false) }

    /// Held by nobody else, once no bed is open.
    func alone() async -> Hold { await take(alone: true) }

    private func take(alone: Bool) async -> Hold {
        if free(for: alone) {
            enter(alone)
        } else {
            await withCheckedContinuation { waiting.append((alone, $0)) }
        }
        return Hold(self, alone: alone)
    }

    private func free(for alone: Bool) -> Bool { !single && (!alone || sharing == 0) }

    private func enter(_ alone: Bool) {
        if alone { single = true } else { sharing += 1 }
    }

    fileprivate func released(_ hold: Hold) {
        if hold.alone { single = false } else { sharing -= 1 }
        // In the order asked, each that can go now.
        var index = 0
        while index < waiting.count {
            let next = waiting[index]
            guard free(for: next.alone) else { index += 1; continue }
            waiting.remove(at: index)
            enter(next.alone)
            next.go.resume()
        }
    }
}

extension MediaPage {
    /// The page's own clock, `performance.now()` in seconds.
    func now() async throws -> Double { try await read("performance.now() / 1000") }

    /// Returns once `seconds` have passed by the page's clock.
    func hold(_ seconds: Double) async throws {
        let until = try await now() + seconds
        try await waitFor("The page's clock never reached \(until) s", timeout: .seconds(seconds + 6)) { try await now() >= until }
    }

    /// Pauses, stays paused `seconds` by the page's clock, and plays again;
    /// answers the picture as it stood paused: just after the pause, half
    /// way through, and just before playing again.
    @discardableResult
    func pause(for seconds: Double) async throws -> Paused {
        try await pause()
        let still = try await still()
        try await hold(seconds / 2)
        let halfWay = try await self.still()
        try await hold(seconds / 2)
        let atPlay = try await self.still()
        try await play()
        return Paused(still: still, halfWay: halfWay, atPlay: atPlay)
    }

    /// The picture on show paused: as the pause took effect (`still`), half
    /// way through (`halfWay`), and as it ended (`atPlay`).
    struct Paused: CustomStringConvertible {
        var still: Still
        var halfWay: Still
        var atPlay: Still

        /// WebKit paused later than its media time says: media time held
        /// where the pause was asked while the media went on, then stood
        /// still, with the picture a frame or more on from where media time
        /// held. On a file or HLS the picture goes on frame by frame after
        /// the pause (`still` to `atPlay`); on Media Source it is on already
        /// as the pause takes effect (`still` ahead of media time, by more
        /// than `ahead`). It stood
        /// still by half way through. Measured 2026-11-27 with four other
        /// beds seeking, changing speed, leaving their tab and going full
        /// screen beside it, the same in a bare `WKWebView`: 1–12 frames on
        /// (numbers on #157).
        var isLate: Bool {
            let frame = 1 / Double(GeneratedMovie.framesPerSecond)
            guard let to = atPlay.frame, halfWay.frame == to, atPlay.current == still.current,
                  halfWay.current == still.current else { return false }
            let wentOn = still.frame.map { to > $0 } ?? false, aheadAtPause = (still.ahead ?? 0) < -Self.ahead
            return (wentOn || aheadAtPause) && Double(to) * frame > still.current
        }

        /// How far ahead of media time the picture on show has been seen
        /// as a pause took effect, unless WebKit made the pause late: 10 ms
        /// (in 264 pauses, measured 2026-11-27). A frame shows from its own
        /// time on, so the picture is otherwise behind media time.
        static let ahead = 0.01

        /// The jumps forward at the play after a late pause (`isLate`) that
        /// come to the frame on show as it ended, within two frames: media
        /// time coming to where the media stopped. The media itself never
        /// jumped: it stopped late and went on from where it stopped.
        func late(_ jumps: [MediaClock.Jump], in clock: MediaClock) -> [MediaClock.Jump] {
            let frame = 1 / Double(GeneratedMovie.framesPerSecond)
            guard isLate, let to = atPlay.frame else { return [] }
            return jumps.filter { jump in
                guard jump.by > 0, jump.after == "play",
                      let landing = clock.samples.first(where: { $0.wall == jump.wall })?.media else { return false }
                return abs(landing - Double(to) * frame) <= 2 * frame
            }
        }

        var description: String { "\(still), \(halfWay) half way, \(atPlay) as it played again" }
    }

    /// The frame on show and the media time, read together while paused,
    /// when no frame comes for `picture()` to read.
    struct Still: Decodable, CustomStringConvertible {
        var frame: Int?
        var current: Double

        /// How far media time is ahead of the picture, in seconds.
        var ahead: Double? { frame.map { current - Double($0) / Double(GeneratedMovie.framesPerSecond) } }

        var description: String {
            String(format: "frame %@ on show paused at %.3f s", frame.map(String.init) ?? "unread", current)
        }
    }

    func still() async throws -> Still {
        try await read("({ frame: \(Self.frameOnShow), current: media.currentTime })")
    }

    /// A script expression: the number the frame on show carries, drawn to
    /// a canvas (`GeneratedMovie`'s squares), or null when it can't be read.
    private static let frameOnShow = """
        (() => {
            const canvas = document.createElement('canvas');
            canvas.width = \(GeneratedMovie.width);
            canvas.height = \(GeneratedMovie.height);
            const context = canvas.getContext('2d', { willReadFrequently: true });
            context.drawImage(media, 0, 0, canvas.width, canvas.height);
            const square = \(GeneratedMovie.frameSquare);
            const row = context.getImageData(0, square / 2, \(GeneratedMovie.frameBits) * square, 1).data;
            let frame = 0, grey = 0;
            for (let bit = 0; bit < \(GeneratedMovie.frameBits); bit += 1) {
                const value = row[(bit * square + square / 2) * 4 + 1];
                if (value > 192) frame |= 1 << bit;
                else if (value > 64) grey += 1;
            }
            return grey ? null : frame;
        })()
        """

    /// Plays at `rate` until `seconds` of media have played, then at 1
    /// again, each change marked `speed` and the rate.
    func changeSpeed(to rate: Double, for seconds: Double = 0.5) async throws {
        try await run("media.playbackRate = \(rate)", mark: "speed \(rate)")
        try await played(beyond: try await state().media + seconds, "at \(rate)")
        try await run("media.playbackRate = 1", mark: "speed 1")
    }

    /// The page's video as it shows now, read in the page as its next frame
    /// is shown: the frame number its picture carries (`GeneratedMovie`'s
    /// squares, drawn to a canvas), the media time WebKit gives that frame,
    /// and the element's `currentTime` then, which the sound follows.
    /// Watching frames changes how WebKit reports media time
    /// (`MediaClock.jumps`), so this is read after a clock, never during.
    struct Picture: Decodable, CustomStringConvertible {
        /// Nil when the canvas can't read the frame (blank, or not ours).
        var frame: Int?
        var shown: Double
        var current: Double
        /// How long after the frame was to be shown the page got to read it
        /// (a busy page reads late, while media time goes on), and the speed.
        /// Known only where WebKit gives the time to be shown on the page's
        /// clock (a file, HLS: 20–30 ms); on Media Source it gives another
        /// clock's, and this is 0.
        var late: Double
        var rate: Double

        /// How far the picture is from the media time: the frame's own time
        /// against `currentTime` as it was when the frame was to be shown.
        var apart: Double? {
            frame.map { Double($0) / Double(GeneratedMovie.framesPerSecond) - (current - late * rate) }
        }

        var description: String {
            String(format: "frame %@ shown at %.3f s, media at %.3f s, read %.0f ms late", frame.map(String.init) ?? "unread", shown, current, late * 1000)
        }
    }

    func picture() async throws -> Picture {
        try await read("""
            await new Promise(resolve => media.requestVideoFrameCallback((when, shown) => {
                resolve({
                    frame: \(Self.frameOnShow), shown: shown.mediaTime, current: media.currentTime,
                    late: (late => late >= 0 && late < 1 ? late : 0)((performance.now() - shown.expectedDisplayTime) / 1000),
                    rate: media.playbackRate,
                });
            }))
            """)
    }
}

extension MediaTestBed {
    /// The page's element in page full screen, as its player's button puts
    /// it: Nerda's own full screen, in the window (`Fullscreen`).
    func enterFullScreen(_ page: MediaPage) async throws {
        try await page.run("await media.requestFullscreen()", mark: "full screen")
        try await waitFor("The page never went full screen") { browser.fullscreenTab == page.tab.id }
    }

    /// Out of page full screen, as Esc or the player's button takes it.
    func leaveFullScreen(_ page: MediaPage) async throws {
        try await page.run("await document.exitFullscreen()", mark: "leave full screen")
        try await waitFor("The page never left full screen") { browser.fullscreenTab == nil }
    }

    /// Another tab shown in the page's place, until the page's media has
    /// played `seconds` out of sight, then the page's tab shown again.
    func leaveAndReturn(_ page: MediaPage, for seconds: Double = 1) async throws {
        try await page.run("", mark: "leave")
        let other = browser.open(URL(string: "about:blank")!)
        defer { browser.close(other.id) }
        try await waitFor("The page was never hidden") { try await page.read("document.visibilityState") == "hidden" }
        try await page.played(beyond: try await page.state().media + seconds, "out of sight")
        try await page.run("", mark: "return")
        browser.select(page.tab.id)
        try await waitFor("The page was never shown again") { try await page.read("document.visibilityState") == "visible" }
    }

    /// The system's notices that the Mac goes to sleep, then, `seconds` by
    /// the page's clock later, that it woke, as the Mac sends them. WebKit
    /// pauses media at the first and plays it again at the second. Reaches
    /// every page of the run: only for a bed that is `alone`.
    func sleepAndWake(_ page: MediaPage, for seconds: Double = 1) async throws {
        let center = NSWorkspace.shared.notificationCenter
        try await page.run("", mark: "sleep")
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try await page.hold(seconds)
        try await page.run("", mark: "wake")
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    }
}
