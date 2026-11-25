import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents type, press keys and choose options (spec #119, ticket #137):
/// text goes in as a person's typing does, so the page's own state follows;
/// keys are the keyboard's own; options are picked as the page expects.
@MainActor
struct AgentTypingTests {
    /// An input whose page keeps its own copy of the value, as React does,
    /// takes the typed text into that copy, not only into the box.
    @Test func typingIntoAControlledInputUpdatesThePagesState() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/controlled", """
            <title>Sign up</title>
            <label>Name <input id=who></label>
            <p id=shown></p>
            <script>
            // As React does: the value it last set is tracked on the box, and an
            // input event whose value matches it is no change at all.
            const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            let tracked = '', state = '';
            Object.defineProperty(who, 'value', {
                configurable: true,
                get() { return native.get.call(this); },
                set(value) { tracked = String(value); native.set.call(this, value); },
            });
            window.events = [];
            who.addEventListener('input', (event) => {
                events.push(event.isTrusted ? 'trusted' : 'script');
                const now = native.get.call(who);
                if (now === tracked) return;
                state = now;
                who.value = state;
                shown.textContent = 'Hello, ' + state;
            });
            </script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let box = try #require(try await ref(of: #"textbox "Name""#, agent))

        let answer = try await agent.call("type", ["tab": "t1", "ref": .string(box), "text": "Ada"])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.hasPrefix(#"typed into \#(box) textbox "Name""#), "\(answer.text)")
        #expect(answer.text.contains(#"\#(box) textbox "Name" = "Ada""#), "\(answer.text)")
        #expect(try await script("return shown.textContent", harness) as? String == "Hello, Ada")
        #expect(try await script("return events", harness) as? [String] == ["trusted"])
    }

    /// A rich text editor that keeps its own model and draws the page from
    /// it, as ProseMirror and Lexical do, takes typed text, lines included,
    /// from the page's own `beforeinput` events.
    @Test func typingIntoARichTextEditorWorks() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/editor", """
            <title>Compose</title>
            <div id=editor contenteditable role=textbox aria-label=Message aria-multiline=true></div>
            <script>
            window.model = [''];
            window.events = [];
            const draw = () => {
                editor.replaceChildren(...model.map((line) => {
                    const p = document.createElement('p');
                    p.textContent = line;
                    return p;
                }));
                const last = editor.lastChild;
                getSelection().collapse(last.firstChild || last, last.textContent.length);
            };
            editor.addEventListener('beforeinput', (event) => {
                event.preventDefault();
                events.push((event.isTrusted ? 'trusted ' : 'script ') + event.inputType);
                if (event.inputType === 'insertText') model[model.length - 1] += event.data;
                if (['insertParagraph', 'insertLineBreak'].includes(event.inputType)) model.push('');
                draw();
            });
            draw();
            </script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let editor = try #require(try await ref(of: #"textbox "Message""#, agent))

        let answer = try await agent.call("type", ["tab": "t1", "ref": .string(editor), "text": "Hi Ada,\nSee you soon"])

        #expect(!answer.isError, "\(answer.text)")
        let events = try await script("return events", harness) as? [String] ?? []
        let model = try await script("return model", harness) as? [String]
        #expect(model == ["Hi Ada,", "See you soon"], "\(String(describing: model)) \(events) \(answer.text)")
        #expect(!events.isEmpty && events.allSatisfy { $0.hasPrefix("trusted ") }, "\(events)")
    }

    /// Lines typed go in as lines, never as the Return key: neither a
    /// box of many lines nor one of a single line sends its form.
    @Test func multiLineTextDoesNotSubmitAForm() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/feedback", """
            <title>Feedback</title>
            <script>window.sent = 0; window.keys = [];
            addEventListener('keydown', (event) => keys.push(event.key), true);</script>
            <form onsubmit="sent++; return false">
              <label>Subject <input id=subject></label>
              <label>Message <textarea id=message></textarea></label>
              <button>Send</button>
            </form>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let subject = try #require(try await ref(of: #"textbox "Subject""#, agent))
        let message = try #require(try await ref(of: #"textbox "Message""#, agent))

        let intoMessage = try await agent.call("type", ["tab": "t1", "ref": .string(message), "text": "First line\nSecond line\n"])
        let intoSubject = try await agent.call("type", ["tab": "t1", "ref": .string(subject), "text": "Two\nlines"])

        #expect(!intoMessage.isError, "\(intoMessage.text)")
        #expect(!intoSubject.isError, "\(intoSubject.text)")
        #expect(try await script("return message.value", harness) as? String == "First line\nSecond line\n")
        #expect(try await script("return subject.value", harness) as? String == "Two lines")
        #expect(try await script("return sent", harness) as? Int == 0)
        #expect(try await script("return keys", harness) as? [String] == [])
    }

    /// Keys are the keyboard's own: the page sees trusted key events, and
    /// they do what they do for a person, ⌘ chords included (⌘A selects
    /// all, Backspace deletes it, Enter sends the form).
    @Test func keyPressesAndCommandChordsArriveAsTrustedEvents() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/search", """
            <title>Search</title>
            <script>window.sent = []; window.keys = [];
            addEventListener('keydown', (e) => keys.push((e.isTrusted ? 'trusted ' : 'script ') + (e.metaKey ? 'Meta+' : '') + e.key), true);</script>
            <form onsubmit="sent.push(query.value); return false">
              <label>Search <input id=query value="old words"></label>
            </form>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let query = try #require(try await ref(of: #"textbox "Search""#, agent))

        let all = try await agent.call("press", ["tab": "t1", "ref": .string(query), "key": "Meta+a"])
        #expect(!all.isError, "\(all.text)")
        #expect(all.text.hasPrefix("pressed ⌘A"), "\(all.text)")
        #expect(try await script("return [query.selectionStart, query.selectionEnd]", harness) as? [Int] == [0, 9])

        let deleted = try await agent.call("press", ["tab": "t1", "key": "Backspace"])
        #expect(!deleted.isError, "\(deleted.text)")
        #expect(try await script("return query.value", harness) as? String == "")

        _ = try await agent.call("type", ["tab": "t1", "ref": .string(query), "text": "cats"])
        let sent = try await agent.call("press", ["tab": "t1", "key": "Enter"])
        #expect(!sent.isError, "\(sent.text)")

        #expect(try await script("return sent", harness) as? [String] == ["cats"])
        #expect(try await script("return keys", harness) as? [String] == ["trusted Meta+a", "trusted Backspace", "trusted Enter"])
    }

    /// choose picks options of a list by what they say (or their value),
    /// and the page's own change handling runs, as when a person picks one.
    @Test func chooseSelectsTheOptionAndFiresThePagesChangeHandling() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/order", """
            <title>Order</title>
            <script>window.heard = [];</script>
            <label>Size <select id=size onchange="heard.push('size ' + this.value)">
              <option value=s>Small</option><option value=m>Medium</option><option value=l>Large</option>
            </select></label>
            <label>Extras <select id=extras multiple onchange="heard.push('extras ' + [...extras.selectedOptions].map((o) => o.value))">
              <option value=cheese>Cheese</option><option value=olives>Olives</option><option value=basil>Basil</option>
            </select></label>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let size = try #require(try await ref(of: #"combobox "Size""#, agent))
        let extras = try #require(try await ref(of: #"listbox "Extras""#, agent))

        let large = try await agent.call("choose", ["tab": "t1", "ref": .string(size), "option": "Large"])
        let toppings = try await agent.call("choose", ["tab": "t1", "ref": .string(extras), "options": ["cheese", "Basil"]])
        let unknown = try await agent.call("choose", ["tab": "t1", "ref": .string(size), "option": "Huge"])

        #expect(!large.isError, "\(large.text)")
        #expect(large.text.hasPrefix(#"chose "Large" in \#(size) combobox "Size""#), "\(large.text)")
        #expect(!toppings.isError, "\(toppings.text)")
        let heard = try await script("return heard", harness) as? [String]
        #expect(heard == ["size l", "extras cheese,basil"], "\(String(describing: heard))")
        #expect(unknown.isError)
        #expect(unknown.text.contains(#""Small", "Medium", "Large""#), "\(unknown.text)")
    }

    /// What an agent typed is its own work, not a draft of the owner's:
    /// the agent can leave the page without a "Leave this page?" question
    /// nobody would see, and its tab closes once its session is done.
    @Test func anAgentsTypingIsNoDraftOfTheOwners() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let next = try await harness.pages.serve("/thanks", "<title>Thanks</title><p>Thanks for writing</p>")
        let url = try await harness.pages.serve("/write", """
            <title>Write</title>
            <label>Note <textarea id=note></textarea></label>
            <label>Urgent <input type=checkbox id=urgent></label>
            <label>Topic <select><option>Billing</option><option>Shipping</option></select></label>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        let note = try #require(AgentClickTests.ref(of: #"textbox "Note""#, in: outline), "\(outline)")
        let urgent = try #require(AgentClickTests.ref(of: #"checkbox "Urgent""#, in: outline), "\(outline)")
        let topic = try #require(AgentClickTests.ref(of: #"combobox "Topic""#, in: outline), "\(outline)")

        _ = try await agent.call("type", ["tab": "t1", "ref": .string(note), "text": "Please call me"])
        _ = try await agent.call("press", ["tab": "t1", "key": "Space", "ref": .string(urgent)])
        _ = try await agent.call("choose", ["tab": "t1", "ref": .string(topic), "option": "Shipping"])
        #expect(try await script("return note.value + ' ' + urgent.checked", harness) as? String == "Please call me true")

        let started = ContinuousClock.now
        let left = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(next)])
        #expect(!left.isError, "\(left.text)")
        #expect(left.text.contains("Thanks for writing"), "\(left.text)")
        #expect(ContinuousClock.now - started < .seconds(10))

        harness.clock.advance(by: AgentSessions.idleLimit)
        harness.server.cleanUp()
        #expect(harness.agents?.tabs.isEmpty == true)
    }

    /// A field in a frame from another site (an embedded sign-in, a card
    /// form) takes typing as one in the page does.
    @Test func typingIntoAFieldInAFrameFromAnotherSiteWorks() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        try await harness.pages.serve("/card", """
            <title>Card</title>
            <script>window.events = [];</script>
            <label>Name on card <input id=holder oninput="events.push(event.isTrusted)"></label>
            """)
        let card = try await harness.pages.url("/card", host: "localhost")
        let url = try await harness.pages.serve("/checkout", """
            <title>Checkout</title>
            <label>Email <input id=email></label>
            <iframe title=Card src="\(card)"></iframe>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        var outline = ""
        try await waitFor {
            outline = try await agent.call("snapshot", ["tab": "t1"]).text
            return outline.contains("Name on card")
        }
        let holder = try #require(AgentClickTests.ref(of: #"textbox "Name on card""#, in: outline), "\(outline)")

        let answer = try await agent.call("type", ["tab": "t1", "ref": .string(holder), "text": "Ada Lovelace"])

        #expect(!answer.isError, "\(answer.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        let frame = try #require(await AgentPage.frames(of: page)?.children.first?.info)
        let typed = try await page.callAsyncJavaScript("return [holder.value, events]", in: frame, contentWorld: .page) as? [Any]
        #expect(typed?.first as? String == "Ada Lovelace", "\(String(describing: typed))")
        #expect(typed?.last as? [Bool] == [true], "\(String(describing: typed))")
        #expect(try await script("return email.value", harness) as? String == "")
    }

    // MARK: - Helpers

    /// The ref of the first outline line naming `element`, from a fresh snapshot.
    private func ref(of element: String, _ agent: AgentTestClient, tab: String = "t1") async throws -> String? {
        let outline = try await agent.call("snapshot", ["tab": .string(tab)]).text
        return AgentClickTests.ref(of: element, in: outline)
    }

    /// Runs `body` in the page's own world of the first Agent tab.
    private func script(_ body: String, _ harness: AgentHarness) async throws -> Any? {
        let page = try #require(harness.agents?.tabs.first?.page)
        return try await page.callAsyncJavaScript(body, contentWorld: .page)
    }
}
