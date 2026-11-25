import Foundation
import WebKit

/// Reading a page: its outline with refs, and its plain text, and waiting
/// for what it shows.
nonisolated extension AgentVerb {
    static let readingVerbs: [AgentVerb] = [snapshot, text, wait]

    static let snapshot = AgentVerb(
        name: "snapshot",
        summary: """
            Read an Agent tab's page as an outline: one line for each element, `- e7 textbox "Email" = "value" (state)`, \
            indented by nesting. By default only what can be clicked, typed into or chosen, with headings and forms; \
            full gives every element and its text, and ref gives only that element and what is in it. A ref (e7, or \
            f2e5 in a frame from another site) stays the same while its element is on the page. The header says what \
            the page needs (password, one-time code, captcha) and which services it signs in with.
            """,
        arguments: [
            .tab,
            .boolean("full", "Every element and its text, not only what can be used"),
            .string("ref", "Only this element and what is in it, such as e12", required: false),
        ],
        readOnly: true
    ) { call in
        let tab = try call.tab()
        let ref = call.optionalString("ref").flatMap { $0.isEmpty ? nil : $0 }
        let reading = try await AgentPage.read(tab, full: call.arguments["full"]?.bool ?? false, ref: ref)
        return AgentPage.answer(tab, reading)
    }

    static let text = AgentVerb(
        name: "text",
        summary: """
            Read an Agent tab's page as plain text, as a person sees it, without refs: the cheapest way to read. \
            Text a person can't see is left out, and counted in the header.
            """,
        arguments: [.tab],
        readOnly: true
    ) { call in
        let tab = try call.tab()
        let read = try await AgentPage.text(of: tab)
        var lines = AgentPage.header(tab)
        if read.hiddenPassages > 0 {
            lines.append(AgentPage.hiddenLine(passages: read.hiddenPassages, characters: read.hiddenCharacters))
        }
        let cap = AgentPage.outlineCap
        lines += ["", AgentPage.untrusted(String(read.text.prefix(cap)))]
        if read.text.count > cap {
            lines.append("(\(read.text.count - cap) more characters cut: narrow with snapshot and a ref)")
        }
        return lines.joined(separator: "\n")
    }

    /// The longest `wait` waits, in seconds: inside its deadline, and
    /// short of the minute Codex gives a call.
    static let longestWait = 50

    static let wait = AgentVerb(
        name: "wait",
        summary: """
            Wait for text to show on an Agent tab's page (any case, spaces as they come), or with load for the \
            page to finish loading, up to timeout seconds: 10 unless given, at most \(longestWait). Answers as \
            click does: what changed on the page while it waited. Fails as timed out when it didn't come.
            """,
        arguments: [
            .tab,
            .string("text", "The text to wait for, as the page shows it", required: false),
            .boolean("load", "Wait for the page to finish loading"),
            .integer("timeout", "Seconds to wait, at most \(longestWait); 10 unless given"),
        ],
        readOnly: true, deadline: .seconds(longestWait + 10)
    ) { call in
        let tab = try call.tab()
        let text = call.optionalString("text").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let load = call.arguments["load"]?.bool ?? false
        guard text != nil || load else { throw AgentError(.invalid, "Give text to wait for, or load: true.") }
        let seconds = min(Double(longestWait), max(0, call.arguments["timeout"]?.number ?? 10))
        let until = min(ContinuousClock.now + .seconds(seconds), call.deadline - .seconds(5))
        let what = [text.map { "\(AgentPage.untrustedInline(String(reflecting: $0))) to show" }, load ? "the page to load" : nil]
            .compactMap(\.self).joined(separator: " and ")
        return try await AgentPage.act(tab, for: call) {
            guard await AgentPage.waitFor(text, load: load, in: tab, until: until) else {
                throw AgentError(.timedOut, """
                    Waited \(Int(seconds)) s for \(what) on tab \(tab.ref), and it didn't. Read the page with text or \
                    snapshot, or wait longer.
                    """)
            }
            return "waited for \(what) on \(tab.ref)"
        }
    }
}

extension AgentPage {
    /// Waits until the tab's page shows `text` (in any of its frames, any
    /// case, spaces as they come) and, with `load`, has finished loading,
    /// or `until` passes: false then. A dialog coming to hold the page ends
    /// the wait, for the answer to tell.
    static func waitFor(_ text: String?, load: Bool, in agentTab: AgentTab, until: ContinuousClock.Instant) async -> Bool {
        let tab = agentTab.tab
        while true {
            if PageNotices.held(tab) != nil { return true }
            var done = !load || (!tab.isLoading && tab.page?.isLoading == false && tab.page?.url != nil)
            if done, load { done = await isComplete(tab) }
            if done, let text { done = await shows(text, in: tab) }
            if done { return true }
            if ContinuousClock.now >= until { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether the tab's page shows `text`, in any frame.
    private static func shows(_ text: String, in tab: Tab) async -> Bool {
        guard let page = tab.page else { return false }
        let frames: [WKFrameInfo?] = await frames(of: page)?.all.map(\.info) ?? [nil]
        for frame in frames {
            let found = await unlessHeld(tab, by: .now + .seconds(1)) {
                try await page.callAsyncJavaScript("""
                    const plain = (words) => (words || '').replace(/\\s+/g, ' ').toLowerCase();
                    return plain(document.body?.innerText).includes(plain(text).trim());
                    """, arguments: ["text": text], in: frame, contentWorld: world) as? Bool ?? false
            }
            if found == true { return true }
        }
        return false
    }
}
