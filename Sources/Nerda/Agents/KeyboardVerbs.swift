import Foundation
import WebKit

/// The keyboard's verbs: typing text into a field or an editor, pressing
/// keys (⌘ chords included), and choosing options of a list. Each answers,
/// as every action does (`AgentPage.act`), with what it changed.
nonisolated extension AgentVerb {
    static let keyboardVerbs: [AgentVerb] = [type, press, choose]

    static let type = AgentVerb(
        name: "type",
        summary: """
            Type text into a field or a rich text editor of an Agent tab's page, by its ref, as a person's \
            typing: the page's own handling (React-style inputs, editors) sees it. Replaces what the field \
            holds unless append is true. Line breaks go in as new lines, never as a Return key, so typing \
            never sends a form: press Enter for that. Answers with what came, went or changed.
            """,
        arguments: [
            .tab,
            .string("ref", "The field or editor to type into, as snapshot named it, such as e7"),
            .string("text", "The text to type; empty to clear the field"),
            .boolean("append", "Add to what the field holds, after it, rather than replace it"),
        ]
    ) { call in
        let tab = try call.tab()
        let ref = try call.string("ref")
        guard let text = call.arguments["text"]?.string else { throw AgentError(.invalid, "Give text as a string.") }
        let append = call.arguments["append"]?.bool ?? false
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.type(text, into: ref, in: tab, append: append)
        }
    }

    static let press = AgentVerb(
        name: "press",
        summary: """
            Press a key on an Agent tab's page, as the keyboard does: the page sees the key's own events. \
            Name it as Enter, Tab, Escape, Backspace, Delete, ArrowDown, PageDown, F5 or a character, with \
            modifiers before it: Meta+a (⌘A), Shift+Tab, Control+Alt+k. Goes to the element with the \
            keyboard's focus, or to ref, focused first. Enter in a form's field sends the form. Answers with \
            what came, went or changed. Enter or Space that pays (on a pay button, or sending a form with \
            card fields) waits for the user's Touch ID, as click does.
            """,
        arguments: [
            .tab,
            .string("key", "The key, such as Enter, ArrowDown, a or Meta+a"),
            .string("ref", "The element to focus first, as snapshot named it, such as e7", required: false),
        ],
        waitsForOwner: true
    ) { call in
        let tab = try call.tab()
        let key = try AgentInput.Key(try call.string("key"))
        let ref = call.optionalString("ref")
        try await call.server.payments.clear(.key(key, ref: ref), on: tab, for: call,
                                             again: "press \(key.name)" + (ref.map { " on \($0)" } ?? ""))
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.press(key, on: ref, in: tab)
        }
    }

    static let choose = AgentVerb(
        name: "choose",
        summary: """
            Choose an option of a list (a select: combobox or listbox) of an Agent tab's page, by its ref, \
            and the option by what it says or its value; options for a list that takes several. The page's \
            own change handling runs, as when a person picks it. Answers with what came, went or changed.
            """,
        arguments: [
            .tab,
            .string("ref", "The list, as snapshot named it, such as e9"),
            .string("option", "The option to choose, by what it says (or its value)", required: false),
            AgentArgument(name: "options", schema: [
                "type": "array", "items": ["type": "string"],
                "description": "For a list that takes several: every option to choose, the others let go of",
            ], required: false),
        ]
    ) { call in
        let tab = try call.tab()
        let ref = try call.string("ref")
        let options = call.arguments["options"]?.array?.compactMap(\.string) ?? call.optionalString("option").map { [$0] } ?? []
        guard !options.isEmpty else { throw AgentError(.invalid, "Give option as a string, or options as a list of strings.") }
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.choose(options, in: ref, of: tab)
        }
    }
}

extension AgentPage {
    /// Chooses `options` of the list `ref` names, each by what it says or
    /// its value (the others let go of), then tells the page as a person's
    /// pick would: `input`, then `change`.
    static func choose(_ options: [String], in ref: String, of agentTab: AgentTab) async throws -> String {
        let element = try await element(ref, in: agentTab)
        let result = try await run(chooseScript, on: element, arguments: ["wanted": options]) as? [String: Any] ?? [:]
        let what = describe(ref: ref, result["what"])
        if let refusal = result["refused"] as? String {
            throw AgentError(.failed, "\(what) \(refusal).")
        }
        if let missing = result["missing"] as? String {
            let offered = (result["options"] as? [String] ?? []).map { String(reflecting: $0) }.joined(separator: ", ")
            throw AgentError(.invalid, "\(what) has no option \(String(reflecting: missing)). Its options: \(offered).")
        }
        let chose = (result["chose"] as? [String] ?? options).map { String(reflecting: $0) }.joined(separator: ", ")
        return "chose \(chose) in \(what)"
    }

    /// Finds each wanted option (by what it says exactly, then its value,
    /// then what it says in any case), selects them, and sends `input` and
    /// `change`. Answers `{what, chose}`, `{what, missing, options}` or
    /// `{what, refused}`.
    private static let chooseScript = """
        const what = nerdaAgent.describe(element);
        if (!(element instanceof HTMLSelectElement)) {
            return { what, refused: "is no list of options (a select), so nothing can be chosen in it: click the option you want instead" };
        }
        if (element.disabled) return { what, refused: 'is disabled, so nothing can be chosen in it' };
        const options = [...element.options];
        const said = (option) => (option.label || option.textContent).replace(/\\s+/g, ' ').trim();
        const picked = [];
        for (const want of wanted) {
            const found = options.find((option) => said(option) === want.trim())
                || options.find((option) => option.value === want)
                || options.find((option) => said(option).toLowerCase() === want.trim().toLowerCase());
            if (!found) return { what, missing: want, options: options.slice(0, 40).map(said) };
            if (found.disabled) return { what, refused: `can't take "${said(found)}": that option is disabled` };
            if (!picked.includes(found)) picked.push(found);
        }
        if (!element.multiple && picked.length > 1) return { what, refused: 'takes one option only' };
        element.focus();
        if (element.multiple) for (const option of options) option.selected = picked.includes(option);
        else element.selectedIndex = picked[0].index;
        element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        return { what, chose: picked.map(said) };
        """

    /// Presses `key` on the tab's page (`AgentInput.press`), on the element
    /// `ref` names, focused first, or on whatever has the focus.
    static func press(_ key: AgentInput.Key, on ref: String?, in agentTab: AgentTab) async throws -> String {
        guard let ref else {
            guard let page = agentTab.tab.page else {
                throw AgentError(.failed, "Tab \(agentTab.ref) has no page loaded. Open an address in it with navigate.")
            }
            try AgentInput.press(key, on: page)
            return "pressed \(key.name)"
        }
        let element = try await element(ref, in: agentTab)
        let what = describe(ref: ref, try await run("""
            element.focus();
            return nerdaAgent.describe(element);
            """, on: element))
        try AgentInput.press(key, on: element.page)
        return "pressed \(key.name) on \(what)"
    }

    /// Types `text` into the field or editor `ref` names: focused, its
    /// content selected (or the caret put at its end, to `append`), then the
    /// text inserted natively, as the Mac's text input inserts it, so the
    /// page sees trusted `beforeinput` and `input` events. Should the page
    /// hear none of it and the field stay as it was, its value is set with
    /// the native value setter (out of reach of a page's own setter, as
    /// React's), and an `input` event sent, and a notice says so. A page
    /// that heard the typing and made something else of it (a phone number
    /// formatted, an editor's own model) is left as it made it.
    static func type(_ text: String, into ref: String, in agentTab: AgentTab, append: Bool) async throws -> String {
        let element = try await element(ref, in: agentTab)
        let ready = try await run(focusScript, on: element, arguments: ["append": append]) as? [String: Any] ?? [:]
        let what = describe(ref: ref, ready["what"])
        if let refusal = ready["refused"] as? String {
            throw AgentError(.failed, "\(what) \(refusal), so it can't be typed into.")
        }
        let page = element.page
        let focused = ready["focused"] as? Bool ?? false
        if text.isEmpty, focused {
            if !append { _ = try await run("element.ownerDocument.execCommand('delete'); return true", on: element) }
        }
        // Line by line, each break a new line as Shift-Return makes it (a
        // chat's box doesn't send on it), never Return; a one-line field
        // takes spaces for them.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let multiline = ready["multiline"] as? Bool ?? false
        for (index, line) in lines.enumerated() where focused {
            if index > 0 {
                if !multiline {
                    page.insertText(" ")
                } else if page.responds(to: #selector(NSResponder.insertLineBreak(_:))) {
                    page.insertLineBreak(nil)
                } else {
                    _ = try await run("element.ownerDocument.execCommand('insertLineBreak'); return true", on: element)
                }
            }
            if !line.isEmpty { page.insertText(String(line)) }
        }
        let took = try await run(tookScript, on: element) as? Bool ?? true
        if !took, !text.isEmpty || !focused {
            _ = try await run(setScript, on: element, arguments: ["text": text, "append": append])
            AgentNotices.post("the page took no typing into \(ref), so Nerda set its value by script", on: agentTab.tab)
        }
        return text.isEmpty && !append ? "cleared \(what)" : "typed into \(what)"
    }

    /// Focuses the element to type into and selects what it holds (or puts
    /// the caret at its end, to `append`), and listens for the page hearing
    /// the typing. Answers `{what, multiline}`, or `{what, refused}` with
    /// why it can't be typed into.
    private static let focusScript = """
        const what = nerdaAgent.describe(element);
        const field = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement;
        const typed = ['text', 'search', 'email', 'url', 'tel', 'password', 'number'];
        if (element instanceof HTMLInputElement && !typed.includes(element.type)) return { what, refused: `is a ${element.type} input, not a field for text` };
        if (!field && !element.isContentEditable) return { what, refused: 'is no field or editor' };
        if (element.disabled) return { what, refused: 'is disabled' };
        if (field && element.readOnly) return { what, refused: 'is read-only' };
        const multiline = !(element instanceof HTMLInputElement);
        element.focus({ preventScroll: false });
        // The page's focus handling may come a moment later, and move it.
        await new Promise((done) => setTimeout(done, 0));
        const page = element.ownerDocument;
        if (field) {
            if (append) {
                try { element.setSelectionRange(element.value.length, element.value.length); } catch {}
            } else element.select();
        } else {
            const range = page.createRange();
            range.selectNodeContents(element);
            if (append) range.collapse(false);
            const selection = page.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
        }
        // Typed text goes where the focus is: should it not have come here
        // (an inert part of the page), nothing is typed natively at all.
        const active = element.getRootNode().activeElement;
        const focused = !!active && (active === element || active.contains(element) || element.contains(active));
        const typing = { heard: false, before: field ? element.value : element.innerText, document: page };
        typing.listener = (event) => { if (event.isTrusted) typing.heard = true; };
        for (const type of ['beforeinput', 'input']) page.addEventListener(type, typing.listener, true);
        nerdaAgent.typing = typing;
        return { what, multiline, focused };
        """

    /// Whether the page heard the typing, or the element changed; the
    /// listener let go of either way.
    private static let tookScript = """
        const typing = nerdaAgent.typing;
        if (!typing) return true;
        nerdaAgent.typing = null;
        for (const type of ['beforeinput', 'input']) typing.document.removeEventListener(type, typing.listener, true);
        const now = element.isContentEditable ? element.innerText : element.value;
        return typing.heard || now !== typing.before;
        """

    /// Sets the element's value with the native setter (this world's own,
    /// which a page's script can't replace), or an editor's text, and tells
    /// the page, as typing would: `input`, then `change`.
    private static let setScript = """
        if (element.isContentEditable) {
            if (!append) element.replaceChildren();
            text.split('\\n').forEach((line, index) => {
                if (index) element.append(element.ownerDocument.createElement('br'));
                element.append(line);
            });
        } else element.value = append ? element.value + text : text;
        element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
        """
}
