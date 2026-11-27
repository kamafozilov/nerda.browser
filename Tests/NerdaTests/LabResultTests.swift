import Foundation
import Lab
import Testing

/// The lab run's result file (`./lab.sh`): what it holds for each site and
/// action, read back as JSON, fed with made-up measurements. The visits to
/// real sites are the measurement, never run here.
struct LabResultTests {
    static let started = Date(timeIntervalSince1970: 1_795_000_000)

    /// A run of two sites, one played and one that wouldn't, and the two
    /// comparisons, one measured and one left out.
    static let run = LabRun(
        started: started, ended: started.addingTimeInterval(600),
        nerda: "Nerda Test 0.0.31 (aeef6fa)",
        mac: LabRun.Mac(system: "macOS 27.2.1", load: [12.5, 9.1, 8.0], output: "MacBook Pro Speakers"),
        safety: LabRun.Safety(checks: 4800, broken: []),
        sites: [
            LabRun.Site(
                name: "YouTube watch page", url: "https://www.youtube.com/watch?v=example",
                outcome: .played, facts: ["reached": "https://www.youtube.com/watch?v=example", "ads": "none seen"],
                actions: [
                    LabRun.Action(
                        action: .pauseAndPlay,
                        media: LabRun.Media(samples: 312, jumps: ["+0.087 s at media 12.400 s, after play"], stalls: []),
                        sound: .measured(lostMs: 12, faults: ["gap at 2.010 s: 1003 ms of silence, 12 ms lost"]),
                        droppedFrames: 0),
                    LabRun.Action(
                        action: .floatAndLand,
                        media: LabRun.Media(samples: 400, jumps: [], stalls: []),
                        sound: .notMeasured("the site's own sound has no sweep to compare with"),
                        droppedFrames: 3,
                        floating: LabRun.Floating(floatedMs: 45, landedMs: 620)),
                    LabRun.Action(action: .seek, skipped: "the stream has nowhere to seek to"),
                ]),
            LabRun.Site(
                name: "Instagram, signed out", url: "https://www.instagram.com/reel/example/",
                outcome: .wouldNotPlay("a sign-in wall covered the reel"), facts: ["reached": "https://www.instagram.com/accounts/login/"],
                actions: []),
        ],
        comparisons: [
            LabRun.Comparison(browser: "Safari, private window", sound: .notMeasured("Safari opens a private window only from its menu or a key")),
            LabRun.Comparison(browser: "Chrome, data of its own", sound: .measured(lostMs: 4, faults: [])),
        ])

    @Test func eachSiteAndActionIsInTheFileWithItsMeasurements() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Self.run.file()) as? [String: Any])
        let sites = try #require(file["sites"] as? [[String: Any]])
        #expect(sites.map { $0["name"] as? String } == ["YouTube watch page", "Instagram, signed out"])

        let youtube = try #require(sites[0]["actions"] as? [[String: Any]])
        #expect(youtube.map { $0["action"] as? String } == ["pause and play", "float and land", "seek"])
        let pause = youtube[0]
        let media = try #require(pause["media"] as? [String: Any])
        #expect(media["continuous"] as? Bool == false)
        #expect(media["jumps"] as? [String] == ["+0.087 s at media 12.400 s, after play"])
        let sound = try #require(pause["sound"] as? [String: Any])
        #expect(sound["measured"] as? Bool == true)
        #expect(sound["lostMs"] as? Double == 12)
        #expect(pause["droppedFrames"] as? Int == 0)

        let float = youtube[1]
        let floating = try #require(float["floating"] as? [String: Any])
        #expect(floating["floatedMs"] as? Double == 45)
        #expect(floating["landedMs"] as? Double == 620)
        #expect((float["media"] as? [String: Any])?["continuous"] as? Bool == true)
        #expect((float["sound"] as? [String: Any])?["measured"] as? Bool == false)
        #expect((float["sound"] as? [String: Any])?["reason"] as? String == "the site's own sound has no sweep to compare with")
        #expect(youtube[2]["skipped"] as? String == "the stream has nowhere to seek to")

        let comparisons = try #require(file["comparisons"] as? [[String: Any]])
        #expect(comparisons.map { $0["browser"] as? String } == ["Safari, private window", "Chrome, data of its own"])
        #expect((comparisons[1]["sound"] as? [String: Any])?["lostMs"] as? Double == 4)
        #expect((comparisons[0]["sound"] as? [String: Any])?["measured"] as? Bool == false)
        #expect((file["mac"] as? [String: Any])?["load"] as? [Double] == [12.5, 9.1, 8.0])
    }

    @Test func theFileReadsBackAsTheRunItWasWrittenFrom() throws {
        #expect(try LabRun.read(Self.run.file()) == Self.run)
    }

    @Test func aSiteThatWouldNotPlayIsToldSoAndNeverPassed() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Self.run.file()) as? [String: Any])
        let instagram = try #require((file["sites"] as? [[String: Any]])?[1])
        let outcome = try #require(instagram["outcome"] as? [String: Any])
        #expect(outcome["status"] as? String == "would not play")
        #expect(outcome["reason"] as? String == "a sign-in wall covered the reel")
        #expect(instagram["passed"] as? Bool == false)

        let unreachable = LabRun.Site(name: "X", url: "https://x.com/example", outcome: .unreachable("no answer in 30 s"), facts: [:], actions: [])
        #expect(!unreachable.passed)
        #expect(Self.run.summary.contains("| Instagram, signed out | would not play: a sign-in wall covered the reel |"))
    }

    @Test func anActionPassesOnlyWithMediaRunningOnAndSoundUnderTheBudget() {
        let clean = LabRun.Media(samples: 100, jumps: [], stalls: [])
        #expect(LabRun.Action(action: .pauseAndPlay, media: clean, sound: .measured(lostMs: 19, faults: []), droppedFrames: 0).passed == true)
        #expect(LabRun.Action(action: .pauseAndPlay, media: clean, sound: .measured(lostMs: 21, faults: []), droppedFrames: 0).passed == false)
        #expect(LabRun.Action(action: .pauseAndPlay, media: clean, sound: .measured(lostMs: -25, faults: []), droppedFrames: 0).passed == false)
        #expect(LabRun.Action(action: .seek, media: LabRun.Media(samples: 100, jumps: [], stalls: ["0.120 s lost at media 3.000 s, after seek"]),
                              sound: .notMeasured("no sweep"), droppedFrames: 0).passed == false)
        #expect(LabRun.Action(action: .floatAndLand, media: clean, sound: .notMeasured("no sweep"), droppedFrames: 0,
                              floating: LabRun.Floating(floatedMs: nil, landedMs: nil, reason: "Nerda chose no video to float")).passed == false)
        // Nothing measured is no pass either way.
        #expect(LabRun.Action(action: .seek, skipped: "live").passed == nil)
        #expect(LabRun.Action(action: .speed, failed: "the page never answered").passed == false)
    }

    @Test func theSummaryHasARowForEachActionOfASitePlayed() {
        let summary = Self.run.summary
        #expect(summary.contains("| YouTube watch page | pause and play | +0.087 s at media 12.400 s, after play | 12 ms | 0 | – |"))
        #expect(summary.contains("| YouTube watch page | float and land | runs on | not measured: the site's own sound has no sweep to compare with | 3 | 45 ms, landed 620 ms |"))
        #expect(summary.contains("| YouTube watch page | seek | skipped: the stream has nowhere to seek to |"))
        #expect(summary.contains("| Chrome, data of its own | 4 ms |"))
        #expect(summary.contains("| Safari, private window | not measured: Safari opens a private window only from its menu or a key |"))
    }
}
