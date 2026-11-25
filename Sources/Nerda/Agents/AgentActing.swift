import Foundation
import WebKit

/// What an agent's action set off besides what changed in the page: a tab
/// it opened, a dialog it raised, a click Nerda had to make by script. Kept
/// per tab until the next answer about that tab (`AgentPage.act`) takes
/// them, so one raised between actions (a timer's alert) is told too.
///
/// Anything can post one: `post("raised an alert: \"Saved\"", on: tab)`.
/// Each shows in the answer as a line `notice: …` under the header.
@MainActor
enum PageNotices {
    private final class Box {
        var lines: [String] = []
        /// Dialogs the page waits on now, by hold.
        var holds: [ObjectIdentifier: String] = [:]
    }

    private static let boxes = NSMapTable<Tab, Box>.weakToStrongObjects()

    private static func box(_ tab: Tab) -> Box {
        if let box = boxes.object(forKey: tab) { return box }
        let box = Box()
        boxes.setObject(box, forKey: tab)
        return box
    }

    /// A notice for the next answer about `tab`.
    static func post(_ line: String, on tab: Tab) {
        box(tab).lines.append(line)
    }

    /// The tab's notices, oldest first, taken: each is told once.
    static func take(from tab: Tab) -> [String] {
        guard let box = boxes.object(forKey: tab) else { return [] }
        defer { box.lines = [] }
        return box.lines
    }

    /// A dialog the page raised and waits on (alert, confirm, prompt, a
    /// leave-page question): posted as a notice, and until `end()` the page
    /// can't run script, so nothing reads it and actions on it are refused.
    /// The delegate showing the dialog holds it for as long as it is up.
    static func hold(_ tab: Tab?, _ line: String) -> DialogHold? {
        guard let tab else { return nil }
        let hold = DialogHold(tab: tab)
        post(line, on: tab)
        box(tab).holds[ObjectIdentifier(hold)] = line
        return hold
    }

    /// What the tab's page waits on, if a dialog holds it.
    static func held(_ tab: Tab) -> String? {
        boxes.object(forKey: tab)?.holds.values.first
    }

    final class DialogHold {
        private weak var tab: Tab?

        fileprivate init(tab: Tab) { self.tab = tab }

        /// The dialog was answered: the page runs again.
        func end() {
            guard let tab else { return }
            boxes.object(forKey: tab)?.holds[ObjectIdentifier(self)] = nil
        }
    }
}

/// Acting on a page and answering with what it did: the one way every
/// action verb (click, type, press, hover, drag, scroll, a dialog's answer…)
/// answers, so they all tell the agent the same things the same way.
extension AgentPage {
    /// How long the page must go without a change in its document to count
    /// as settled, once it has loaded.
    static let quietFor = Duration.milliseconds(150)
    /// The longest an action waits for its page to settle.
    static let settleAtMost = Duration.milliseconds(2500)
    /// Past this many lines changed (or half the outline), the answer is
    /// the whole outline rather than what changed.
    static let largeChange = 20

    /// Does `action` on the tab's page, waits for the page to settle
    /// (loading done, then `quietFor` without a change, at most
    /// `settleAtMost`), and answers:
    /// - the action's own line (what `action` returns, such as `clicked e7
    ///   button "Send"`), then the header (`header(_:_:)`) and the
    ///   notices (`PageNotices`), among them each new tab the action
    ///   opened, which joins the session;
    /// - then what came, went or changed in the outline, by ref; or, after
    ///   a navigation, the new page as `open` answers it; or, after a large
    ///   change, the whole outline;
    /// - or, while a dialog holds the page, only that.
    /// Fails at once, doing nothing, while a dialog already holds the page.
    ///
    /// A new action verb is its own `AgentVerb` whose `run` resolves its
    /// arguments, then `return try await AgentPage.act(tab, for: call) { …
    /// return "typed into e7" }`; what it finds out on the way it posts to
    /// `PageNotices`.
    ///
    /// `answeringDialog`: the action answers the dialog holding the page
    /// (the `dialog` verb), so the page can't be read before it: the answer
    /// is the whole outline, or the new page after a navigation.
    static func act(_ agentTab: AgentTab, for call: AgentCall, answeringDialog: Bool = false,
                    _ action: () async throws -> String) async throws -> String {
        let tab = agentTab.tab
        if !answeringDialog, let held = PageNotices.held(tab) {
            throw AgentError(.failed, "Tab \(agentTab.ref)'s page waits on a dialog (\(held)), so it can't be acted on until that is answered with dialog.")
        }
        let soon = ContinuousClock.now + .seconds(2)
        let before = await unlessHeld(tab, by: soon) { try await read(agentTab) }
        let document = await unlessHeld(tab, by: soon) { try await documentMark(of: tab) }
        let address = tab.url
        let tabsBefore = Set(agentTab.agents.tabs.map(ObjectIdentifier.init))

        await markActing(tab, true)
        let did: String
        do { did = try await action() } catch {
            await markActing(tab, false)
            throw error
        }

        await settle(tab, until: min(.now + settleAtMost, call.deadline - .seconds(1)))
        await markActing(tab, false)
        let opened = adoptNewTabs(of: agentTab, besides: tabsBefore, for: call)
        var notices = opened.map { "notice: opened a new tab \($0.ref): \($0.tab.url?.absoluteString ?? "") (snapshot \($0.ref) reads it)" }
        let downloading = await AgentDownloads.settle(tab, until: min(.now + AgentDownloads.waitAtMost, call.deadline - .seconds(1)))
        notices += (PageNotices.take(from: tab) + downloading).map { "notice: " + $0 }

        if PageNotices.held(tab) != nil {
            return ([did] + header(agentTab) + notices + ["", "The page waits on its dialog: nothing in it can be read or done until the dialog is answered with dialog."])
                .joined(separator: "\n")
        }
        let after = await unlessHeld(tab, by: .now + .seconds(3)) { try await read(agentTab) } ?? AgentReading()
        let navigated = answeringDialog
            ? !sameDocument(address, tab.url)
            : await unlessHeld(tab, by: .now + .seconds(1)) { try await documentMark(of: tab) } != document
                || !sameDocument(address, tab.url)
        if navigated {
            return await shown(agentTab, after, did: did, notices: notices, text: true)
        }
        guard let before else { return await shown(agentTab, after, did: did, notices: notices, text: false) }
        let change = changes(from: before.lines, to: after.lines)
        let count = change.came.count + change.went.count + change.changed.count
        if count > max(largeChange, after.lines.count / 2) {
            return await shown(agentTab, after, did: did, notices: notices + ["much of the page changed: its whole outline follows"], text: false)
        }
        var lines = [did] + header(agentTab, after) + notices + [""]
        if count == 0 {
            lines.append("Nothing in the page's outline changed.")
        } else {
            var parts: [String] = []
            if !change.came.isEmpty { parts += ["came:"] + change.came }
            if !change.went.isEmpty { parts += ["went:"] + change.went }
            if !change.changed.isEmpty { parts += ["changed:"] + change.changed }
            lines.append(untrusted(parts.joined(separator: "\n"), as: "page-changes"))
        }
        return lines.joined(separator: "\n")
    }

    /// A whole page as an agent is shown it: the header and notices, the
    /// outline, and with `text` the start of its text (as `open` answers).
    static func shown(_ agentTab: AgentTab, _ reading: AgentReading, did: String? = nil,
                      notices: [String] = [], text: Bool) async -> String {
        var lines = (did.map { [$0] } ?? []) + header(agentTab, reading) + notices
        if agentTab.tab.isLoading { lines.append("still loading: what follows is what has arrived so far") }
        lines += ["", untrusted(reading.outline(), as: "page-outline")]
        guard text else { return lines.joined(separator: "\n") }
        let pageText = await unlessHeld(agentTab.tab, by: .now + .seconds(3)) { try await self.text(of: agentTab).text } ?? ""
        lines.append("")
        lines.append(untrusted(String(pageText.prefix(textStart))))
        if pageText.count > textStart { lines.append("(\(pageText.count - textStart) more characters of text: read them all with text)") }
        return lines.joined(separator: "\n")
    }

    /// What came, went and changed between two outlines, as outline lines
    /// without their indent: a line with a ref is the same element while its
    /// ref is; other lines (text) by what they say.
    static func changes(from before: [String], to after: [String]) -> (came: [String], went: [String], changed: [String]) {
        func key(_ line: String) -> String {
            line.firstMatch(of: #/^- ((?:f\d+)?e\d+) /#).map { String($0.output.1) } ?? line
        }
        let old = before.map { $0.trimmingCharacters(in: .whitespaces) }
        let new = after.map { $0.trimmingCharacters(in: .whitespaces) }
        let oldByKey = Dictionary(old.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let newKeys = Set(new.map(key))
        var came: [String] = [], changed: [String] = []
        for line in new {
            guard let was = oldByKey[key(line)] else { came.append(line); continue }
            if was != line { changed.append(line) }
        }
        let went = old.filter { !newKeys.contains(key($0)) }
        return (came, went, changed)
    }

    /// Runs `work` unless a dialog comes to hold the tab's page first, or
    /// `deadline` passes: nil then, or when `work` fails. A page held by a
    /// dialog runs no script, so a call into it would wait as long as the
    /// dialog is up; this one is let go of and finishes unheard.
    static func unlessHeld<Value>(_ tab: Tab, by deadline: ContinuousClock.Instant,
                                  _ work: @escaping () async throws -> Value) async -> Value? {
        guard PageNotices.held(tab) == nil else { return nil }
        let race = Race<Value>()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task {
                race.finish(try? await work())
            }
            Task {
                while !race.isOver {
                    if PageNotices.held(tab) != nil || ContinuousClock.now >= deadline { race.finish(nil) }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
    }

    private final class Race<Value> {
        var continuation: CheckedContinuation<Value?, Never>?
        private(set) var isOver = false

        func finish(_ value: sending Value?) {
            guard !isOver else { return }
            isOver = true
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Waits until the page has loaded and then gone `quietFor` without a
    /// change in its document, or a dialog holds it, or `end`.
    private static func settle(_ tab: Tab, until end: ContinuousClock.Instant) async {
        while ContinuousClock.now < end, PageNotices.held(tab) == nil {
            guard let page = tab.page, !tab.isLoading, !page.isLoading else {
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            let quiet = await unlessHeld(tab, by: end) {
                try await page.callAsyncJavaScript(
                    quietScript, arguments: ["quiet": quietFor.milliseconds, "most": (end - .now).milliseconds],
                    contentWorld: world
                ) as? Bool
            }
            // A load the action started (a link, a form) may only begin now.
            if quiet == true, !tab.isLoading, !page.isLoading { return }
            if quiet == nil { try? await Task.sleep(for: .milliseconds(25)) }
        }
    }

    /// Resolves once `quiet` milliseconds have gone without a change in the
    /// document, true; or false at `most` milliseconds.
    private static let quietScript = """
        return await new Promise((resolve) => {
            const start = performance.now();
            let last = start;
            const observer = new MutationObserver(() => { last = performance.now(); });
            observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            const tick = () => {
                const now = performance.now();
                if (now - last >= quiet || now - start >= most) {
                    observer.disconnect();
                    resolve(now - last >= quiet);
                } else setTimeout(tick, 20);
            };
            setTimeout(tick, 20);
        });
        """

    /// Marks the time an agent acts on the tab's page, in each of its
    /// frames, so what the agent types, picks or drops isn't taken for a
    /// draft of the owner's (`PageActivity`): a draft keeps the tab from
    /// cleanup and asks "Leave this page?" before the agent may go on. The
    /// mark ends by itself, should a dialog keep it from being taken away.
    private static func markActing(_ tab: Tab, _ acting: Bool) async {
        guard let page = tab.page else { return }
        let tree = await unlessHeld(tab, by: .now + .seconds(1)) { await frames(of: page) } ?? nil
        let all: [WKFrameInfo?] = tree?.all.map(\.info) ?? [nil]
        for frame in all {
            _ = await unlessHeld(tab, by: .now + .seconds(1)) {
                try await page.callAsyncJavaScript(
                    "globalThis.nerdaAgentActs = acting ? Date.now() + 15000 : 0", arguments: ["acting": acting],
                    in: frame, contentWorld: .defaultClient
                )
            }
        }
    }

    /// A mark of the main frame's document, the same until another
    /// document replaces it (a navigation, a reload).
    private static func documentMark(of tab: Tab) async throws -> String? {
        try await tab.page?.callAsyncJavaScript(
            "return globalThis.nerdaDocument ??= Date.now().toString(36) + Math.random().toString(36).slice(2)",
            contentWorld: world
        ) as? String
    }

    /// Whether two addresses are of one document: the same but for the part
    /// after #.
    private static func sameDocument(_ one: URL?, _ other: URL?) -> Bool {
        func trimmed(_ url: URL?) -> String? { url?.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) }
        return trimmed(one) == trimmed(other)
    }

    /// The tabs the page opened while acting, as the session's own Agent
    /// tabs. Popups join their opener's browser by themselves (`Browser`);
    /// one that isn't the session's yet is made so here.
    private static func adoptNewTabs(of agentTab: AgentTab, besides before: Set<ObjectIdentifier>, for call: AgentCall) -> [AgentTab] {
        let sessions = call.server.sessions
        let mine = Set(sessions.tabs(of: call.session).map { $0.tab.id })
        let owned = Set(sessions.all.flatMap { sessions.tabs(of: $0) }.map { ObjectIdentifier($0.tab) })
        return agentTab.agents.tabs.filter { !before.contains(ObjectIdentifier($0)) }.compactMap { tab in
            guard let opener = tab.opener, mine.contains(opener) else { return nil }
            if owned.contains(ObjectIdentifier(tab)) {
                return sessions.tabs(of: call.session).first { $0.tab === tab }
            }
            return sessions.add(tab, in: agentTab.agents, to: call.session)
        }
    }
}
