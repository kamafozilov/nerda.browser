import Foundation

/// What one lab run found (`./lab.sh`): for each site and each action, did
/// media time run on without a jump, how much sound was lost, how many
/// frames the page said it dropped, and how long floating and landing
/// took. Written as one JSON file per run (`file()`), with a summary in
/// Markdown beside it (`summary`).
public struct LabRun: Codable, Equatable, Sendable {
    public var started: Date
    public var ended: Date
    /// Which Nerda Test was measured: its version and commit.
    public var nerda: String
    public var mac: Mac
    /// That nothing came forward while it ran, and how it was checked.
    public var safety: Safety
    public var sites: [Site]
    /// The same sound across a pause and play in other browsers.
    public var comparisons: [Comparison]

    public init(started: Date, ended: Date, nerda: String, mac: Mac, safety: Safety, sites: [Site], comparisons: [Comparison]) {
        self.started = started
        self.ended = ended
        self.nerda = nerda
        self.mac = mac
        self.safety = safety
        self.sites = sites
        self.comparisons = comparisons
    }

    public struct Mac: Codable, Equatable, Sendable {
        public var system: String
        /// The load average over 1, 5 and 15 minutes as the run started.
        public var load: [Double]
        /// The sound output in use, by name.
        public var output: String?

        public init(system: String, load: [Double], output: String?) {
            self.system = system
            self.load = load
            self.output = output
        }
    }

    /// The run looked, every so often, at which app was in front and which
    /// of Nerda Test's windows were on a screen: `broken` says each time
    /// one was, which ends the run.
    public struct Safety: Codable, Equatable, Sendable {
        public var checks: Int
        public var broken: [String]
        /// How the pages were found to play unheard, before any site.
        public var quiet: String?

        public init(checks: Int, broken: [String], quiet: String? = nil) {
            self.checks = checks
            self.broken = broken
            self.quiet = quiet
        }
    }

    /// One site, as it was reached signed out, and what each action did there.
    public struct Site: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var outcome: Outcome
        /// What was seen on the way, as found: the address reached, ads,
        /// walls, the video's size and kind.
        public var facts: [String: String]
        public var actions: [Action]

        public init(name: String, url: String, outcome: Outcome, facts: [String: String], actions: [Action]) {
            self.name = name
            self.url = url
            self.outcome = outcome
            self.facts = facts
            self.actions = actions
        }

        /// Played, and every action done passed. A site not reached, or
        /// that wouldn't play signed out, never passes.
        public var passed: Bool {
            outcome == .played && !actions.isEmpty && actions.allSatisfy { $0.passed != false }
                && actions.contains { $0.passed == true }
        }

        enum CodingKeys: String, CodingKey { case name, url, outcome, facts, actions, passed }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try values.decode(String.self, forKey: .name), url: try values.decode(String.self, forKey: .url),
                      outcome: try values.decode(Outcome.self, forKey: .outcome),
                      facts: try values.decode([String: String].self, forKey: .facts),
                      actions: try values.decode([Action].self, forKey: .actions))
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name)
            try values.encode(url, forKey: .url)
            try values.encode(outcome, forKey: .outcome)
            try values.encode(facts, forKey: .facts)
            try values.encode(actions, forKey: .actions)
            try values.encode(passed, forKey: .passed)
        }
    }

    /// Whether a site's media played signed out, and if not, why.
    public enum Outcome: Codable, Equatable, Sendable {
        case played
        /// The page couldn't be loaded.
        case unreachable(String)
        /// It loaded, but its video didn't play: a wall (consent, sign-in),
        /// an ad that never ended, no video found.
        case wouldNotPlay(String)

        public var status: String {
            switch self {
            case .played: "played"
            case .unreachable: "unreachable"
            case .wouldNotPlay: "would not play"
            }
        }

        public var reason: String? {
            switch self {
            case .played: nil
            case .unreachable(let reason), .wouldNotPlay(let reason): reason
            }
        }

        enum CodingKeys: String, CodingKey { case status, reason }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self = switch try values.decode(String.self, forKey: .status) {
            case "played": .played
            case "unreachable": .unreachable(reason)
            default: .wouldNotPlay(reason)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(status, forKey: .status)
            try values.encodeIfPresent(reason, forKey: .reason)
        }
    }

    /// What the run does to a playing video.
    public enum ActionName: String, Codable, Sendable, CaseIterable {
        case pauseAndPlay = "pause and play"
        case seek
        case speed = "change speed"
        case fullScreen = "full screen in and out"
        case leaveAndReturn = "leave the tab and return"
        case floatAndLand = "float and land"
    }

    /// One action on one site: measured, or skipped or failed and why.
    public struct Action: Codable, Equatable, Sendable {
        public var action: ActionName
        public var media: Media?
        public var sound: Sound?
        /// Frames the page reported dropped while it ran
        /// (`getVideoPlaybackQuality`).
        public var droppedFrames: Int?
        public var floating: Floating?
        /// Not done here, and why (a live stream can't seek).
        public var skipped: String?
        /// Begun and not finished, and what went wrong.
        public var failed: String?
        /// The sound recorded across it, a WAV file beside the result.
        public var recording: String?

        public init(action: ActionName, media: Media, sound: Sound, droppedFrames: Int?, floating: Floating? = nil) {
            self.action = action
            self.media = media
            self.sound = sound
            self.droppedFrames = droppedFrames
            self.floating = floating
        }

        public init(action: ActionName, skipped reason: String) {
            self.action = action
            skipped = reason
        }

        public init(action: ActionName, failed reason: String) {
            self.action = action
            failed = reason
        }

        /// Media ran on, sound lost (if measured) under the Budget, and the
        /// video floated and landed (for that action); nil when nothing
        /// was measured.
        public var passed: Bool? {
            if failed != nil { return false }
            guard let media else { return nil }
            if !media.continuous { return false }
            if case .measured(let lost, _) = sound, abs(lost) >= LabRun.soundBudgetMs { return false }
            if action == .floatAndLand, floating?.floatedMs == nil || floating?.landedMs == nil { return false }
            return true
        }
    }

    /// Sound lost across a pause and play, as the spec's Budget has it: under 20 ms.
    public static let soundBudgetMs = 20.0

    /// The page's media clock across the action (`MediaClock`).
    public struct Media: Codable, Equatable, Sendable {
        public var samples: Int
        /// Media time moving where the wall clock didn't let it.
        public var jumps: [String]
        /// Media time standing still while playing, then going on.
        public var stalls: [String]

        public init(samples: Int, jumps: [String], stalls: [String]) {
            self.samples = samples
            self.jumps = jumps
            self.stalls = stalls
        }

        public var continuous: Bool { jumps.isEmpty && stalls.isEmpty }

        enum CodingKeys: String, CodingKey { case samples, jumps, stalls, continuous }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(samples: try values.decode(Int.self, forKey: .samples), jumps: try values.decode([String].self, forKey: .jumps),
                      stalls: try values.decode([String].self, forKey: .stalls))
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(samples, forKey: .samples)
            try values.encode(jumps, forKey: .jumps)
            try values.encode(stalls, forKey: .stalls)
            try values.encode(continuous, forKey: .continuous)
        }
    }

    /// The sound recorded across the action, against what it should have been.
    public enum Sound: Codable, Equatable, Sendable {
        /// `lostMs`: sound lost (positive) or heard twice (negative) at the
        /// action; `faults` everything the comparison found.
        case measured(lostMs: Double, faults: [String])
        case notMeasured(String)

        enum CodingKeys: String, CodingKey { case measured, lostMs, faults, reason }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if try values.decode(Bool.self, forKey: .measured) {
                self = .measured(lostMs: try values.decode(Double.self, forKey: .lostMs), faults: try values.decode([String].self, forKey: .faults))
            } else {
                self = .notMeasured(try values.decode(String.self, forKey: .reason))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .measured(let lost, let faults):
                try values.encode(true, forKey: .measured)
                try values.encode(lost, forKey: .lostMs)
                try values.encode(faults, forKey: .faults)
            case .notMeasured(let reason):
                try values.encode(false, forKey: .measured)
                try values.encode(reason, forKey: .reason)
            }
        }
    }

    /// Floating and landing's **Latency**, as Nerda's record timed them:
    /// from the leave to WebKit's word it floats, from the return to its
    /// word it landed. Nil when it didn't, and why.
    public struct Floating: Codable, Equatable, Sendable {
        public var floatedMs: Double?
        public var landedMs: Double?
        public var reason: String?

        public init(floatedMs: Double?, landedMs: Double?, reason: String? = nil) {
            self.floatedMs = floatedMs
            self.landedMs = landedMs
            self.reason = reason
        }
    }

    /// Another browser playing the sweep across a pause and play.
    public struct Comparison: Codable, Equatable, Sendable {
        public var browser: String
        public var sound: Sound

        public init(browser: String, sound: Sound) {
            self.browser = browser
            self.sound = sound
        }
    }

    // MARK: - the file

    public func file() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func read(_ file: Data) throws -> LabRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LabRun.self, from: file)
    }

    // MARK: - the summary

    /// The run in Markdown: a row for each site's action, then the comparisons.
    public var summary: String {
        var lines = [
            "Lab run of \(nerda), \(Self.day.string(from: started)), \(Int(ended.timeIntervalSince(started) / 60)) min, on \(mac.system)"
                + (mac.output.map { ", sound out through \($0)" } ?? "")
                + ", load \(mac.load.map { String(format: "%.1f", $0) }.joined(separator: " / ")).",
            "",
            safety.broken.isEmpty
                ? "Nothing came forward: \(safety.checks) checks of the app in front and Nerda Test's windows on screen."
                : "**Not as it should have been:** " + safety.broken.joined(separator: "; "),
        ]
        if let quiet = safety.quiet { lines += ["", quiet] }
        lines += [
            "",
            "| Site | Action | Media time | Sound lost | Frames dropped | Floating |",
            "|---|---|---|---|---|---|",
        ]
        for site in sites {
            guard site.outcome == .played else {
                lines.append("| \(site.name) | \(site.outcome.status): \(site.outcome.reason ?? "") |  |  |  |  |")
                continue
            }
            for action in site.actions {
                if let reason = action.skipped ?? action.failed.map({ "failed: \($0)" }) {
                    let said = action.skipped != nil ? "skipped: \(reason)" : reason
                    lines.append("| \(site.name) | \(action.action.rawValue) | \(said) |  |  |  |")
                    continue
                }
                let media = action.media.map { $0.continuous ? "runs on" : ($0.jumps + $0.stalls).joined(separator: "; ") } ?? "–"
                let dropped = action.droppedFrames.map(String.init) ?? "–"
                lines.append("| \(site.name) | \(action.action.rawValue) | \(media) | \(Self.said(action.sound)) | \(dropped) | \(Self.said(action.floating)) |")
            }
        }
        lines += ["", "| Browser | Sound lost across a pause and play |", "|---|---|"]
        for comparison in comparisons { lines.append("| \(comparison.browser) | \(Self.said(comparison.sound)) |") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func said(_ sound: Sound?) -> String {
        switch sound {
        case .measured(let lost, _)?: String(format: "%.0f ms", lost)
        case .notMeasured(let reason)?: "not measured: \(reason)"
        case nil: "–"
        }
    }

    static func said(_ floating: Floating?) -> String {
        guard let floating else { return "–" }
        guard let floated = floating.floatedMs else { return "didn't float: \(floating.reason ?? "")" }
        let landed = floating.landedMs.map { String(format: "landed %.0f ms", $0) } ?? "didn't land: \(floating.reason ?? "")"
        return String(format: "%.0f ms, ", floated) + landed
    }

    static let day: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format
    }()
}
