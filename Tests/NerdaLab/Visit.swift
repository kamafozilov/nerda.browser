import Foundation
import Lab
import MediaCheck
import SoundCheck

/// One site's visit: reached, its video found and started as the owner
/// would, then each action done to it and measured.
@MainActor
struct Visit {
    let spec: SiteSpec
    let nerda: NerdaTest
    let media: LocalMedia
    /// Why sound can't be recorded on this Mac, if it can't.
    let soundRefused: String?
    /// Where each action's recording is kept.
    var recordings: URL?

    struct Stop: Error, CustomStringConvertible {
        var outcome: LabRun.Outcome
        var description: String { "\(outcome.status): \(outcome.reason ?? "")" }
    }

    private(set) var facts: [String: String] = [:]
    private var tab = 0
    private var behind = 0
    private var frame = 0

    init(spec: SiteSpec, nerda: NerdaTest, media: LocalMedia, soundRefused: String?) {
        self.spec = spec
        self.nerda = nerda
        self.media = media
        self.soundRefused = soundRefused
    }

    mutating func run() async -> LabRun.Site {
        var actions: [LabRun.Action] = []
        let outcome: LabRun.Outcome
        do {
            try await reach()
            try await findAndStart()
            for action in LabRun.ActionName.allCases {
                actions.append(await measure(action))
                await recover()
            }
            outcome = .played
        } catch let stop as Stop {
            outcome = stop.outcome
        } catch {
            outcome = .wouldNotPlay("\(error)")
        }
        for id in [tab, behind] where id > 0 { _ = try? await nerda.send("close", ["tab": id]) }
        return LabRun.Site(name: spec.name, url: spec.shown, outcome: outcome, facts: facts, actions: actions)
    }

    // MARK: - reaching the video

    private mutating func reach() async throws {
        let url: URL = switch spec.address {
        case .web(let address): URL(string: address)!
        case .embed(let video): try await media.embedding(video)
        case .twitchLive: URL(string: "https://www.twitch.tv/directory/all")!
        case .localFile: try await media.file()
        case .localHLS: try await media.hls()
        }
        // The tab left for and returned to, opened behind first: opening a
        // tab selects it, which would be a leave of the video's.
        behind = try await nerda.send("open", ["url": "about:blank"]) as? Int ?? 0
        tab = try await nerda.send("open", ["url": url.absoluteString]) as? Int ?? 0
        try await loaded()
        if case .twitchLive = spec.address {
            let channel = try await run(#"""
                await new Promise(done => setTimeout(done, 3000));
                const card = document.querySelector('a[data-a-target="preview-card-image-link"]');
                return card ? card.href : '';
                """#, frame: 0, timeout: 30) as? String ?? ""
            guard let live = URL(string: channel), !channel.isEmpty else {
                throw Stop(outcome: .wouldNotPlay("Twitch listed no live channel signed out"))
            }
            facts["channel"] = channel
            _ = try await run("location.assign(\(Probe.json(live.absoluteString))); return true;", frame: 0)
            try await Task.sleep(for: .seconds(1))
            try await loaded()
        }
    }

    /// The tab's page loaded, or the reason it couldn't be.
    private mutating func loaded() async throws {
        let deadline = Date().addingTimeInterval(30)
        var state: [String: Any] = [:]
        repeat {
            try await Task.sleep(for: .milliseconds(500))
            state = try await nerda.send("state", ["tab": tab]) as? [String: Any] ?? [:]
        } while state["loading"] as? Bool == true && Date() < deadline
        let reached = state["url"] as? String ?? ""
        facts["reached"] = reached
        if state["loading"] as? Bool == true { throw Stop(outcome: .unreachable("still loading after 30 s")) }
        if reached.isEmpty || reached == "about:blank" { throw Stop(outcome: .unreachable("no page came")) }
        if let wall = SiteSpec.wall(at: reached) { throw Stop(outcome: .wouldNotPlay("\(wall) stood before the video")) }
    }

    /// Finds the largest video in any frame, past the site's ads and
    /// gates, starts it as the owner would press play, and waits for its
    /// media time to run.
    private mutating func findAndStart() async throws {
        let deadline = Date().addingTimeInterval(90)
        var pressed = Date().addingTimeInterval(8), seen: Set<String> = []
        while true {
            guard Date() < deadline else {
                facts["at the end"] = await described()
                throw Stop(outcome: .wouldNotPlay("no video played within 90 s" + (seen.isEmpty ? "" : " (seen: \(seen.sorted().joined(separator: ", ")))")))
            }
            if let reached = (try? await nerda.send("state", ["tab": tab]) as? [String: Any])?["url"] as? String,
               let wall = SiteSpec.wall(at: reached) {
                facts["reached"] = reached
                throw Stop(outcome: .wouldNotPlay("\(wall) stood before the video"))
            }
            var obstacle = ""
            for index in 0..<((try? await frames()) ?? 1) where obstacle.isEmpty {
                obstacle = (try? await run(spec.obstacle, frame: index) as? String) ?? ""
            }
            if obstacle.hasPrefix("error") { throw Stop(outcome: .wouldNotPlay("the player said \(obstacle)")) }
            if !obstacle.isEmpty {
                seen.insert(obstacle)
                facts["seen"] = seen.sorted().joined(separator: ", ")
                try await Task.sleep(for: .seconds(1))
                if obstacle.hasPrefix("ad") || obstacle.hasPrefix("consent") { continue }
            }
            guard let found = try await largestVideo() else {
                // A player that makes its video only once played (an embed),
                // or that wouldn't start by itself: its play button, every 10 s.
                if Date() > pressed {
                    pressed = Date().addingTimeInterval(10)
                    for index in 0..<((try? await frames()) ?? 1) {
                        if let said = try? await run(spec.playerPlay, frame: index, world: "page") as? String, !said.isEmpty {
                            facts["asked"] = said
                            for refusal in ["UNPLAYABLE", "LOGIN_REQUIRED", "ERROR", "AGE_CHECK"] where said.contains("playable \(refusal)") {
                                throw Stop(outcome: .wouldNotPlay("the player says: \(said)"))
                            }
                        } else if let said = try? await run(Probe.start, frame: index) as? String, said != "none" {
                            facts["pressed"] = said
                        }
                    }
                }
                try await Task.sleep(for: .seconds(1))
                continue
            }
            frame = found
            _ = try await run(Probe.watch, frame: frame)
            let started = try await run(Probe.start, frame: frame) as? String ?? ""
            facts["started by"] = started
            do {
                _ = try await run(Probe.played(1, limit: 15), frame: frame, timeout: 20)
            } catch {
                facts["not playing"] = "\(error)"
                try await Task.sleep(for: .seconds(1))
                continue
            }
            // Ads end: the video in sight may be the ad's. Played and none showing: it's the site's.
            if !((try? await run(spec.obstacle, frame: 0) as? String) ?? "").isEmpty { continue }
            break
        }
        // Pressed as the owner would, then heard long enough for Nerda's
        // floating rule (three seconds).
        if try await run(Probe.ownersPlay, frame: frame, world: "page") as? Bool == true { facts["muted as it came"] = "yes, unmuted as the owner would" }
        try await Task.sleep(for: .milliseconds(500))
        // A live player may start its stream again after a pause, in another element.
        _ = try await run(Probe.watch, frame: frame)
        _ = try await run(Probe.played(3.5, limit: 30), frame: frame, timeout: 35)
        if let state = try await run(Probe.state, frame: frame) as? String {
            facts["video"] = state
            if state.contains("\"muted\":true") {
                facts["muted still"] = "the site kept its video muted: Nerda's floating rule floats only a video playing with sound"
                facts["labels"] = try? await run("return [...new Set([...document.querySelectorAll('[aria-label]')].map(e => e.tagName + ':' + e.getAttribute('aria-label')))].slice(0, 60).join(' | ');", frame: frame, world: "page") as? String
            }
        }
        facts["frame"] = frame == 0 ? "main" : "frame \(frame)"
    }

    /// Every frame's address and its videos, for a site where none played.
    private func described() async -> String {
        guard let frames = try? await nerda.send("frames", ["tab": tab]) as? [[String: Any]] else { return "no frames" }
        var said: [String] = []
        for (index, frame) in frames.enumerated() {
            let videos = (try? await run(Probe.describe, frame: index) as? String) ?? "unanswered"
            let title = (try? await run("return document.title + ' / ' + document.readyState;", frame: index) as? String) ?? ""
            said.append("frame \(index) \(frame["url"] as? String ?? "") (\(title)): \(videos)")
        }
        return said.joined(separator: "; ")
    }

    private func frames() async throws -> Int {
        (try await nerda.send("frames", ["tab": tab]) as? [Any])?.count ?? 1
    }

    /// The frame holding the largest video with something to play.
    private func largestVideo() async throws -> Int? {
        var best: (frame: Int, area: Int)?
        for index in 0..<(try await frames()) {
            guard let described = try? await run(Probe.describe, frame: index) as? String,
                  let videos = try? JSONSerialization.jsonObject(with: Data(described.utf8)) as? [[String: Any]] else { continue }
            for video in videos where (video["readyState"] as? Int ?? 0) >= 1 {
                let area = video["area"] as? Int ?? 0
                if area > (best?.area ?? -1) { best = (index, area) }
            }
        }
        return best?.frame
    }

    private func run(_ script: String, frame: Int, timeout: Double = 30, world: String = "lab") async throws -> Any {
        try await nerda.send("run", ["tab": tab, "frame": frame, "script": script, "world": world], timeout: timeout)
    }

    // MARK: - the actions

    /// Back to playing at speed 1 in its tab, out of full screen, landed,
    /// whatever the action left.
    private func recover() async {
        _ = try? await nerda.send("floating", ["on": false])
        _ = try? await nerda.send("select", ["tab": tab])
        _ = try? await run("if (document.fullscreenElement) await document.exitFullscreen(); return true;", frame: frame, world: "page")
        _ = try? await run(Probe.script("""
            lab.video.playbackRate = 1;
            if (lab.video.paused) await lab.video.play();
            return true;
            """), frame: frame)
    }

    private func measure(_ action: LabRun.ActionName) async -> LabRun.Action {
        do {
            return try await measuring(action)
        } catch let skip as Skip {
            return LabRun.Action(action: action, skipped: skip.reason)
        } catch {
            return LabRun.Action(action: action, failed: "\(error)")
        }
    }

    struct Skip: Error {
        var reason: String
    }

    private func measuring(_ action: LabRun.ActionName) async throws -> LabRun.Action {
        _ = try await run(Probe.watch, frame: frame)
        _ = try await run(Probe.roomToPlay, frame: frame)
        let before = try decode(try await run(Probe.take, frame: frame))
        // Every site's sound is recorded: on the bed's own media to compare
        // with the sweep, on a site's to show how loud it came out.
        let recorder = soundRefused == nil ? try await SoundRecorder.start(app: nerda.pid) : nil
        var floating: LabRun.Floating?
        var expected: [String] = []
        do {
            _ = try await run(Probe.played(1), frame: frame)
            switch action {
            case .pauseAndPlay:
                _ = try await run(Probe.pauseAndPlay, frame: frame)
                // The site's player may have put a new stream in another element.
                _ = try await run(Probe.watch, frame: frame)
            case .seek:
                let said = try await run(Probe.seek, frame: frame) as? String ?? "{}"
                let answer = try JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any] ?? [:]
                if let skipped = answer["skipped"] as? String { throw Skip(reason: skipped) }
                expected = ["seek"]
            case .speed:
                _ = try await run(Probe.speed, frame: frame)
            case .fullScreen:
                _ = try await run(Probe.mark("full screen"), frame: frame)
                _ = try await run(Probe.fullScreenIn, frame: frame, world: "page")
                _ = try await run(Probe.script("await lab.hold(2); lab.mark('leave full screen'); return true;"), frame: frame)
                _ = try await run(Probe.fullScreenOut, frame: frame, world: "page")
            case .leaveAndReturn:
                _ = try await run(Probe.mark("leave"), frame: frame)
                _ = try await nerda.send("select", ["tab": behind])
                try await Task.sleep(for: .seconds(2))
                _ = try await nerda.send("select", ["tab": tab])
                _ = try await run(Probe.mark("return"), frame: frame)
            case .floatAndLand:
                floating = try await floatAndLand()
            }
            _ = try await run(Probe.played(2), frame: frame, timeout: 25)
        } catch {
            _ = try? await recorder?.stop()
            throw error
        }
        let taken = try decode(try await run(Probe.take, frame: frame))
        let samples = try await recorder?.stop()
        let clock = taken.clock
        var jumps = clock.jumps(over: MediaClock.tolerance)
        // The seek's own jump is what was asked for.
        if let first = jumps.firstIndex(where: { expected.contains($0.after ?? "") }) { jumps.remove(at: first) }
        let media = LabRun.Media(samples: clock.samples.count, jumps: jumps.map(\.description),
                                 stalls: clock.stalls(over: MediaClock.tolerance).map(\.description))
        let dropped = taken.dropped >= 0 && before.dropped >= 0 ? taken.dropped - before.dropped : nil
        var heard = sound(samples, recorder, action)
        // Where the page held its media time paused, beside where the sound
        // stopped and came back: sound queued and dropped at the pause, or
        // lost at the restart.
        if action == .pauseAndPlay, case .measured(let lost, let faults) = heard,
           let pause = clock.marks.first(where: { $0.name == "pause" }),
           let held = clock.samples.first(where: { $0.paused && $0.wall >= pause.wall }) {
            heard = .measured(lostMs: lost, faults: faults + [String(format: "the page paused at currentTime %.3f s", held.media)])
        }
        var measured = LabRun.Action(action: action, media: media, sound: heard, droppedFrames: dropped, floating: floating)
        if let samples, let recordings {
            let name = "\(spec.name)-\(action.rawValue).wav".replacing(" ", with: "-").replacing(",", with: "").lowercased()
            try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            if (try? Wave.write(samples, rate: 48_000, to: recordings.appending(path: name))) != nil {
                measured.recording = "\(recordings.lastPathComponent)/\(name)"
            }
        }
        return measured
    }

    private func floatAndLand() async throws -> LabRun.Floating {
        let lock = try await FloatingLock.take()
        nerda.watch?.flying = true
        defer {
            lock.release()
            nerda.watch?.flying = false
            nerda.watch?.flewUntil = Date().addingTimeInterval(3)
        }
        _ = try await nerda.send("floating", ["on": true])
        let chosen = (try await nerda.send("state", ["tab": tab]) as? [String: Any])?["chosen"] as? Bool ?? false
        let floatsBefore = try await timings("floating"), landsBefore = try await timings("landing")
        _ = try await run(Probe.mark("leave"), frame: frame)
        _ = try await nerda.send("select", ["tab": behind])
        let floated = try await until(floating: true, seconds: 3)
        try await Task.sleep(for: .seconds(2))
        _ = try await nerda.send("select", ["tab": tab])
        _ = try await run(Probe.mark("return"), frame: frame)
        let landed = floated ? try await until(floating: false, seconds: 3) : false
        _ = try await nerda.send("floating", ["on": false])
        let floating = try await timings("floating"), landing = try await timings("landing")
        let reason: String? = if !floated {
            chosen ? "Nerda chose the video, but WebKit never said it floated in 3 s"
                : "Nerda's rule chose no video to float (playing with sound, started by the owner, heard 3 s)"
        } else if !landed { "WebKit never said it landed in 3 s" } else { nil }
        return LabRun.Floating(floatedMs: floated ? floating.count > floatsBefore.count ? floating.last : nil : nil,
                               landedMs: landed ? landing.count > landsBefore.count ? landing.last : nil : nil, reason: reason)
    }

    /// The record's times of `kind`, oldest first, in ms.
    private func timings(_ kind: String) async throws -> [Double] {
        let state = try await nerda.send("state", ["tab": tab]) as? [String: Any] ?? [:]
        let timings = state["timings"] as? [[String: Any]] ?? []
        return timings.filter { $0["kind"] as? String == kind }
            .sorted { ($0["age"] as? Double ?? 0) > ($1["age"] as? Double ?? 0) }
            .compactMap { $0["ms"] as? Double }
    }

    private func until(floating: Bool, seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try await nerda.send("state", ["tab": tab]) as? [String: Any])?["floating"] as? Bool == floating { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func decode(_ value: Any) throws -> Probe.Taken {
        try JSONDecoder().decode(Probe.Taken.self, from: Data((value as? String ?? "{}").utf8))
    }

    // MARK: - the sound

    private func sound(_ samples: [Float]?, _ recorder: SoundRecorder?, _ action: LabRun.ActionName) -> LabRun.Sound {
        guard spec.kind == .local else {
            let loudest = samples.map { Quiet.decibels($0.map(abs).max() ?? 0) } ?? "not recorded"
            return .notMeasured("a site's own sound has no sweep to compare with; it came out at \(loudest) of full scale at its loudest")
        }
        if let soundRefused { return .notMeasured(soundRefused) }
        guard let samples, let recorder else { return .notMeasured("nothing recorded") }
        if action == .seek { return .notMeasured("a seek leaves sound out on purpose") }
        let breaks = recorder.breaks.map { String(format: "screen capture's own delivery broke at %.3f s", $0) }
        guard case .measured(let lost, let faults) = LabRun.Sound.compared(samples, rate: recorder.rate, action: action) else {
            return LabRun.Sound.compared(samples, rate: recorder.rate, action: action)
        }
        return .measured(lostMs: lost, faults: faults + breaks)
    }
}
