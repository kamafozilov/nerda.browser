import Foundation

/// Reading a page: its outline with refs, and its plain text.
nonisolated extension AgentVerb {
    static let readingVerbs: [AgentVerb] = [snapshot, text]

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
}
