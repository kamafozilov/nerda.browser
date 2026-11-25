import Foundation
import WebKit

/// What one reading of a page found: the outline's lines, and what the
/// header says of the page.
struct AgentReading {
    /// The outline, one indented line for each element shown.
    var lines: [String] = []
    /// Text a person can't see, left out: how many passages, how long.
    var hiddenPassages = 0
    var hiddenCharacters = 0
    /// What the page asks for that an agent may not have: a password, a
    /// one-time code, a captcha.
    var needs: Set<String> = []
    /// Buttons that sign in with a service (Google, Apple…), and their refs.
    var signsIn: [(service: String, ref: String)] = []

    /// The outline as text, cut at `cap` characters with how to narrow it.
    func outline(cap: Int = AgentPage.outlineCap) -> String {
        guard !lines.isEmpty else { return "(nothing on this page to click or fill: read it with text)" }
        var kept: [String] = []
        var length = 0
        for line in lines {
            guard length + line.count + 1 <= cap else { break }
            kept.append(line)
            length += line.count + 1
        }
        guard kept.count < lines.count else { return kept.joined(separator: "\n") }
        // Parts that hold others, by their refs, to narrow to.
        let parts = lines.indices.dropLast().filter { depth(of: lines[$0 + 1]) > depth(of: lines[$0]) }
            .compactMap { lines[$0].trimmingCharacters(in: .whitespaces).dropFirst(2).split(separator: " ", maxSplits: 2).prefix(2).joined(separator: " ") }
            .prefix(8)
        var note = "(outline cut at \(cap) characters: \(lines.count - kept.count) more lines. Narrow it: snapshot with ref set to one part"
        note += parts.isEmpty ? ")" : ", such as \(parts.joined(separator: ", ")))"
        return (kept + [note]).joined(separator: "\n")
    }

    private func depth(of line: String) -> Int { line.prefix { $0 == " " }.count }
}

/// An element an agent named by its ref, found: the frame it is in (nil for
/// the main frame) and its page. Got from `AgentPage.element(_:in:)`, used
/// with `AgentPage.run(_:on:)`.
struct AgentElement {
    let ref: String
    let page: WKWebView
    let frame: WKFrameInfo?
}

/// A frame of a page and the frames in it, in the order of the page's
/// `window.frames`.
struct AgentFrame {
    let info: WKFrameInfo
    let children: [AgentFrame]

    init?(_ node: NSObject) {
        guard node.responds(to: NSSelectorFromString("info")), let info = node.value(forKey: "info") as? WKFrameInfo else { return nil }
        self.info = info
        children = (node.value(forKey: "childFrames") as? [NSObject] ?? []).compactMap(AgentFrame.init)
    }

    /// The frame at `path` down from here, by index in each frame's children.
    func frame(at path: [Int]) -> AgentFrame? {
        guard let first = path.first else { return self }
        return children.indices.contains(first) ? children[first].frame(at: Array(path.dropFirst())) : nil
    }

    var all: [AgentFrame] { [self] + children.flatMap(\.all) }
}

/// The page model: pages read as an outline with refs, and their text.
/// Built by `AgentPageScript` in `world`, in each frame read.
extension AgentPage {
    /// The longest outline or text an answer carries.
    static let outlineCap = 40_000

    /// What the header lists the page as needing, in this order.
    private static let needsOrder = ["password", "one-time code", "captcha"]

    /// Reads the tab's page: the interactive outline, every element with
    /// `full`, or only the element `ref` names and what is in it.
    static func read(_ agentTab: AgentTab, full: Bool = false, ref: String? = nil) async throws -> AgentReading {
        let page = try page(of: agentTab)
        let tree = await frames(of: page)
        var reading = AgentReading()
        var arguments: [String: Any] = ["full": full, "providers": SocialSignIn.providers.map(\.name)]
        var start: AgentFrame? = tree
        var isMain = true
        if let ref {
            let found = try await frame(holding: ref, on: page, tree: tree)
            arguments["ref"] = ref
            start = found
            isMain = found == nil || found?.info.isMainFrame == true
        }
        try await read(start, isMain: isMain, on: page, counts: counts(of: agentTab.tab), arguments: arguments, depth: 0, into: &reading)
        return reading
    }

    /// The page's text as a person reads it, frames from other sites
    /// included, what is hidden left out: the text, and the hidden count.
    static func text(of agentTab: AgentTab) async throws -> (text: String, hiddenPassages: Int, hiddenCharacters: Int) {
        let page = try page(of: agentTab)
        let tree = await frames(of: page)
        var hidden = (passages: 0, characters: 0)
        func read(_ frame: AgentFrame?, isMain: Bool) async throws -> String {
            let answer: TextAnswer = try await call("text", in: isMain ? nil : frame?.info, on: page)
            hidden.passages += answer.hidden.passages
            hidden.characters += answer.hidden.characters
            var text = ""
            for part in answer.parts {
                switch part {
                case .text(let piece): text += piece
                case .frame(let path):
                    guard let child = frame?.frame(at: path) else { continue }
                    text += "\n" + ((try? await read(child, isMain: false)) ?? "") + "\n"
                }
            }
            return text
        }
        let text = try await read(tree, isMain: true)
            .replacing(/\n{3,}/, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, hidden.passages, hidden.characters)
    }

    /// The element `ref` names on the tab's page, or `stale_ref` when it is
    /// gone (after the one re-bind the page model tries).
    static func element(_ ref: String, in agentTab: AgentTab) async throws -> AgentElement {
        let page = try page(of: agentTab)
        let frame = try await frame(holding: ref, on: page, tree: await frames(of: page))
        let element = AgentElement(ref: ref, page: page, frame: frame?.info.isMainFrame == true ? nil : frame?.info)
        _ = try await run("return true", on: element)
        return element
    }

    /// Runs `body`, an async function body, in the page model's world in
    /// the element's frame, with `element` bound to it and `arguments` as
    /// locals; answers what it returns (strings, numbers, arrays and
    /// dictionaries). A stale ref fails with `stale_ref`.
    static func run(_ body: String, on element: AgentElement, arguments: [String: Any] = [:]) async throws -> Any? {
        var arguments = arguments
        arguments["op"] = "run"
        arguments["args"] = [String: Any]()
        arguments["prefix"] = ""
        arguments["ref"] = element.ref
        let source = AgentPageScript.source + """

            const element = nerdaAgent.element(ref);
            if (!element) return \(String(reflecting: staleMark));
            return await (async (element) => {
            \(body)
            })(element);
            """
        let result = try await element.page.callAsyncJavaScript(source, arguments: arguments, in: element.frame, contentWorld: world)
        if result as? String == staleMark { throw stale(element.ref) }
        return result
    }

    /// The header with what this reading found: what the page needs, how
    /// it signs in, and how much hidden text was left out.
    static func header(_ agentTab: AgentTab, _ reading: AgentReading) -> [String] {
        var lines = header(agentTab)
        let needs = needsOrder.filter(reading.needs.contains)
        if !needs.isEmpty { lines.append("needs: \(needs.joined(separator: ", "))") }
        if !reading.signsIn.isEmpty {
            lines.append("signs in with: \(reading.signsIn.map { "\($0.service) \($0.ref)" }.joined(separator: ", "))")
        }
        if reading.hiddenPassages > 0 {
            lines.append(hiddenLine(passages: reading.hiddenPassages, characters: reading.hiddenCharacters))
        }
        return lines
    }

    static func hiddenLine(passages: Int, characters: Int) -> String {
        "hidden text left out: \(passages) \(passages == 1 ? "passage" : "passages"), \(characters) characters"
    }

    /// A reading as an agent is shown it: header, then the outline.
    static func answer(_ agentTab: AgentTab, _ reading: AgentReading) -> String {
        (header(agentTab, reading) + ["", untrusted(reading.outline(), as: "page-outline")]).joined(separator: "\n")
    }

    // MARK: - Frames and calls

    private static func page(of agentTab: AgentTab) throws -> WKWebView {
        guard let page = agentTab.tab.page else {
            throw AgentError(.failed, "Tab \(agentTab.ref) has no page loaded. Open an address in it with navigate.")
        }
        return page
    }

    /// Reads one frame into `reading`, and the frames from other sites in
    /// it, each on its own, their refs prefixed.
    private static func read(_ frame: AgentFrame?, isMain: Bool, on page: WKWebView, counts: Counts,
                             arguments: [String: Any], depth: Int, into reading: inout AgentReading) async throws {
        let prefix = isMain ? "" : try await prefix(of: frame, on: page, counts: counts)
        var arguments = arguments
        if isMain { arguments["floor"] = counts.refs }
        let answer: OutlineAnswer = try await call("outline", arguments, in: isMain ? nil : frame?.info, prefix: prefix, on: page)
        if let stale = answer.stale { throw self.stale(stale) }
        if isMain { counts.refs = max(counts.refs, answer.count ?? 0) }
        reading.hiddenPassages += answer.hidden?.passages ?? 0
        reading.hiddenCharacters += answer.hidden?.characters ?? 0
        reading.needs.formUnion(answer.needs ?? [])
        for sign in answer.signs ?? [] where !reading.signsIn.contains(where: { $0.service == sign.provider }) {
            reading.signsIn.append((sign.provider, sign.ref))
        }
        var inner = arguments
        inner["ref"] = nil
        for line in answer.lines ?? [] {
            let indent = String(repeating: "  ", count: depth + line.d)
            if let text = line.t {
                reading.lines.append(indent + "- " + text)
            } else if let path = line.frame {
                guard let child = frame?.frame(at: path) else {
                    reading.lines.append(indent + "- text \"(a frame from another site, which Nerda can't read here)\"")
                    continue
                }
                do {
                    try await read(child, isMain: false, on: page, counts: counts, arguments: inner, depth: depth + line.d, into: &reading)
                } catch {
                    reading.lines.append(indent + "- text \"(a frame from another site, which couldn't be read)\"")
                }
            }
        }
    }

    /// The prefix a frame read on its own gives its refs (f1, f2…): its
    /// own once it has one, else the page's next.
    private static func prefix(of frame: AgentFrame?, on page: WKWebView, counts: Counts) async throws -> String {
        guard let frame else { return "" }
        let own: String? = try await call("prefix", in: frame.info, on: page)
        if let own { return own }
        counts.frames += 1
        return "f\(counts.frames)"
    }

    /// How many refs and frame prefixes a tab has handed out, over every
    /// document it showed and every page it woke with: numbers only go up, so a ref from a page left
    /// behind is stale rather than another element's.
    private final class Counts {
        var refs = 0
        var frames = 0
    }

    private static let counted = NSMapTable<Tab, Counts>.weakToStrongObjects()

    private static func counts(of tab: Tab) -> Counts {
        if let counts = counted.object(forKey: tab) { return counts }
        let counts = Counts()
        counted.setObject(counts, forKey: tab)
        return counts
    }

    /// The frame whose refs start like `ref`'s (f2 for f2e5); nil for the
    /// main frame's (e5). An unknown prefix is a stale ref.
    private static func frame(holding ref: String, on page: WKWebView, tree: AgentFrame?) async throws -> AgentFrame? {
        guard let match = ref.wholeMatch(of: /(f\d+)?e\d+/) else {
            throw AgentError(.invalid, "\(ref) is not a ref. Refs look like e12, or f2e5 in a frame; snapshot lists them.")
        }
        guard let prefix = match.output.1.map(String.init) else { return nil }
        for frame in tree?.all.dropFirst() ?? [] {
            let own: String?? = try? await call("prefix", in: frame.info, on: page)
            if own == prefix { return frame }
        }
        throw stale(ref)
    }

    /// Calls the page model in one frame (nil: the main frame), and decodes
    /// its JSON answer.
    private static func call<Answer: Decodable>(_ op: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                                                prefix: String = "", on page: WKWebView) async throws -> Answer {
        let result = try await page.callAsyncJavaScript(
            AgentPageScript.source, arguments: ["op": op, "args": arguments, "prefix": prefix], in: frame, contentWorld: world
        )
        guard let json = result as? String else { throw AgentError(.failed, "Nerda couldn't read the page.") }
        return try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
    }

    /// The page's frames, through WebKit's frame tree.
    private static func frames(of page: WKWebView) async -> AgentFrame? {
        // WebKit SPI: should `_frames:` go, frames from other sites are named
        // in the outline but not read; the page's own frames still are.
        let selector = NSSelectorFromString("_frames:")
        guard page.responds(to: selector) else { return nil }
        return await withCheckedContinuation { continuation in
            let done: @convention(block) (NSObject?) -> Void = { node in
                MainActor.assumeIsolated { continuation.resume(returning: node.flatMap(AgentFrame.init)) }
            }
            page.perform(selector, with: done)
        }
    }

    private static let staleMark = "nerda-agents:stale-ref"

    private static func stale(_ ref: String) -> AgentError {
        AgentError(.staleRef, "\(ref) is a stale ref: that element is gone from the page. Take a new snapshot and use the refs it gives.")
    }

    // MARK: - Answers of the page model

    private struct OutlineAnswer: Decodable {
        struct Line: Decodable {
            let d: Int
            let t: String?
            let frame: [Int]?
        }
        struct Sign: Decodable {
            let provider: String
            let ref: String
        }
        let lines: [Line]?
        let hidden: Hidden?
        let needs: [String]?
        let signs: [Sign]?
        let count: Int?
        let stale: String?
    }

    private struct Hidden: Decodable {
        let passages: Int
        let characters: Int
    }

    private struct TextAnswer: Decodable {
        enum Part: Decodable {
            case text(String)
            case frame([Int])

            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) { self = .text(text); return }
                self = .frame(try decoder.container(keyedBy: Key.self).decode([Int].self, forKey: .frame))
            }

            private enum Key: CodingKey { case frame }
        }
        let parts: [Part]
        let hidden: Hidden
    }
}
