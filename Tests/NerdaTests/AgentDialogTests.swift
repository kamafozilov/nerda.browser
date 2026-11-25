import Foundation
import Testing
import WebKit
@testable import Nerda

/// Dialogs and popups in Agent tabs (spec #119, ticket #139): an alert is
/// accepted and told, confirm and prompt wait for the dialog verb (or the
/// owner, after a while), leaving a page never asks, and a popup is an
/// Agent tab of the same session, never the owner's.
@MainActor
struct AgentDialogTests {
    /// An alert is accepted at once, its words in the answer, and the page
    /// goes on with what it does after it.
    @Test func anAlertIsAcceptedAndTold() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/save", """
            <title>Save</title>
            <button onclick="alert('Saved'); document.body.insertAdjacentHTML('beforeend', '<button>Next</button>')">Save</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let save = try #require(try await ref(of: #"button "Save""#, agent))

        let answer = try await agent.call("click", ["tab": "t1", "ref": .string(save)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains(#"notice: accepted an alert: <page-text>"Saved"</page-text>"#), "\(answer.text)")
        #expect(answer.text.contains(#"button "Next""#), "\(answer.text)")
    }

    /// A confirm holds the page: the click says so, reading it fails at
    /// once naming the dialog, and the dialog verb's OK lets the page go
    /// on, answered with what that changed.
    @Test func aConfirmWaitsForTheDialogVerb() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/delete", """
            <title>Draft</title>
            <button onclick="document.body.insertAdjacentHTML('beforeend', confirm('Delete the draft?') ? '<button>Deleted</button>' : '<button>Kept</button>')">Delete</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let delete = try #require(try await ref(of: #"button "Delete""#, agent))

        let clicked = try await agent.call("click", ["tab": "t1", "ref": .string(delete)])
        #expect(clicked.text.contains(#"raised a confirm dialog: <page-text>"Delete the draft?"</page-text>"#), "\(clicked.text)")

        let started = ContinuousClock.now
        let read = try await agent.call("snapshot", ["tab": "t1"])
        #expect(read.isError, "\(read.text)")
        #expect(read.text.contains("dialog"), "\(read.text)")
        #expect(ContinuousClock.now - started < .seconds(3))

        let answered = try await agent.call("dialog", ["tab": "t1", "accept": true])

        #expect(!answered.isError, "\(answered.text)")
        #expect(answered.text.contains(#"answered the confirm dialog <page-text>"Delete the draft?"</page-text>: OK"#), "\(answered.text)")
        #expect(answered.text.contains(#"button "Deleted""#), "\(answered.text)")
        let again = try await agent.call("dialog", ["tab": "t1", "accept": true])
        #expect(again.isError, "\(again.text)")
        #expect(harness.server.owner.waiting.isEmpty, "the owner was asked though the agent answered in time")
    }

    /// The pointer's other verbs wait on a dialog as a click does: a drag
    /// whose press brings one up stops there and answers at once, and while
    /// it holds the page, hover, drag and scroll are refused at once.
    @Test func pointerVerbsWaitOnADialogAsAClickDoes() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/board", """
            <title>Board</title>
            <div id=card role=button tabindex=0 onmousedown="document.title = confirm('Move the card?') ? 'Moving' : 'Kept'">Write report</div>
            <section aria-label="Done" style="height: 200px; margin-top: 300px; border: 1px solid"></section>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1", "full": true]).text
        let card = try #require(AgentClickTests.ref(of: #"button "Write report""#, in: outline), "\(outline)")
        let done = try #require(AgentClickTests.ref(of: #"region "Done""#, in: outline), "\(outline)")

        let started = ContinuousClock.now
        let dragged = try await agent.call("drag", ["tab": "t1", "ref": .string(card), "to": .string(done)])
        #expect(!dragged.isError, "\(dragged.text)")
        #expect(dragged.text.hasPrefix("began dragging"), "\(dragged.text)")
        #expect(dragged.text.contains(#"raised a confirm dialog: <page-text>"Move the card?"</page-text>"#), "\(dragged.text)")
        #expect(ContinuousClock.now - started < .seconds(5))

        let calls: [(String, [String: AgentJSON])] = [
            ("hover", ["tab": "t1", "ref": .string(card)]),
            ("drag", ["tab": "t1", "ref": .string(card), "to": .string(done)]),
            ("scroll", ["tab": "t1"]),
        ]
        for (verb, arguments) in calls {
            let started = ContinuousClock.now
            let refused = try await agent.call(verb, arguments)
            #expect(refused.isError, "\(verb): \(refused.text)")
            #expect(refused.text.contains("waits on a dialog"), "\(verb): \(refused.text)")
            #expect(ContinuousClock.now - started < .seconds(3), "\(verb)")
        }

        let answered = try await agent.call("dialog", ["tab": "t1", "accept": false])
        #expect(!answered.isError, "\(answered.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        #expect(try await page.callAsyncJavaScript("return document.title", contentWorld: .page) as? String == "Kept")
    }

    /// A prompt is answered with the agent's text, or cancelled.
    @Test func aPromptTakesTheAgentsText() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/name", """
            <title>Name</title>
            <button onclick="const name = prompt('Your name?', 'Guest'); document.body.insertAdjacentHTML('beforeend', `<button>${name === null ? 'No name' : 'Hello ' + name}</button>`)">Name</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let name = try #require(try await ref(of: #"button "Name""#, agent))

        _ = try await agent.call("click", ["tab": "t1", "ref": .string(name)])
        let typed = try await agent.call("dialog", ["tab": "t1", "accept": true, "text": "Kam"])
        #expect(typed.text.contains(#"button "Hello Kam""#), "\(typed.text)")

        _ = try await agent.call("click", ["tab": "t1", "ref": .string(name)])
        let cancelled = try await agent.call("dialog", ["tab": "t1", "accept": false])
        #expect(cancelled.text.contains(#"button "No name""#), "\(cancelled.text)")
    }

    /// Unanswered for long enough, a confirm goes to the owner, with its
    /// words and buttons; their OK lets the page go on, and the agent hears
    /// of it in its next answer.
    @Test func anUnansweredDialogGoesToTheOwner() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.dialogsReachOwnerAfter = .milliseconds(300)
        let url = try await harness.pages.serve("/delete", """
            <title>Draft</title>
            <button onclick="document.title = confirm('Delete the draft?') ? 'Deleted' : 'Kept'">Delete</button>
            <button onclick="document.title += '!'">Again</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let delete = try #require(try await ref(of: #"button "Delete""#, agent))
        let again = try #require(try await ref(of: #"button "Again""#, agent))
        _ = try await agent.call("click", ["tab": "t1", "ref": .string(delete)])
        let owner = harness.server.owner

        try await waitFor("the dialog never went to the owner") { !owner.waiting.isEmpty }
        let request = try #require(owner.waiting.first)
        #expect(request.text.contains("Delete the draft?"), "\(request.text)")
        #expect(request.choices == ["OK", "Cancel"])
        #expect(request.tab?.ref == "t1")
        #expect(harness.notifier.posted.contains { $0.body.contains("Delete the draft?") })

        owner.pick(request, 0)

        try await waitFor("the page never went on") { harness.agents?.tabs.first?.title == "Deleted" }
        let next = try await agent.call("click", ["tab": "t1", "ref": .string(again)])
        #expect(next.text.contains("the user answered the confirm dialog"), "\(next.text)")
    }

    /// The agent may still answer a dialog that went to the owner: the
    /// owner's question is withdrawn.
    @Test func anAgentsLateAnswerWithdrawsTheOwnersQuestion() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        harness.server.dialogsReachOwnerAfter = .milliseconds(200)
        let url = try await harness.pages.serve("/delete", """
            <title>Draft</title>
            <button onclick="document.title = confirm('Delete the draft?') ? 'Deleted' : 'Kept'">Delete</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let delete = try #require(try await ref(of: #"button "Delete""#, agent))
        _ = try await agent.call("click", ["tab": "t1", "ref": .string(delete)])
        let owner = harness.server.owner
        try await waitFor("the dialog never went to the owner") { !owner.waiting.isEmpty }
        let id = try #require(owner.waiting.first?.id)

        let answered = try await agent.call("dialog", ["tab": "t1", "accept": false])

        #expect(!answered.isError, "\(answered.text)")
        try await waitFor("the owner's question stayed") { owner.waiting.isEmpty }
        #expect(harness.notifier.withdrawn.contains(id))
        #expect(harness.agents?.tabs.first?.title == "Kept")
    }

    /// A page asking whether to leave is left: after the agent clicked in
    /// it (so it may ask), and with something typed in it.
    @Test func leavingAPageThatAsksDoesntBlock() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let form = try await harness.pages.serve("/form", """
            <title>Form</title>
            <script>addEventListener('beforeunload', (e) => { e.preventDefault(); e.returnValue = 'Stay?'; });</script>
            <textarea id=note></textarea><button onclick="this.textContent = 'Touched'">Touch</button>
            """)
        let other = try await harness.pages.serve("/other", "<title>Other</title><p>Elsewhere</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(form)])
        let touch = try #require(try await ref(of: #"button "Touch""#, agent))
        _ = try await agent.call("click", ["tab": "t1", "ref": .string(touch)])
        let tab = try #require(harness.agents?.tabs.first)
        _ = try await tab.page?.evaluateJavaScript("note.focus(); document.execCommand('insertText', false, 'draft')")
        try await waitFor("nothing typed") { tab.hasUnsavedWork }

        let started = ContinuousClock.now
        let left = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(other)])

        #expect(!left.isError, "\(left.text)")
        #expect(left.text.contains("Elsewhere"), "\(left.text)")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// A page asking whether to leave, with nothing typed in it, is left
    /// too: its question (beforeunload) is answered leave.
    @Test func aLeavePageQuestionIsAnsweredLeave() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let form = try await harness.pages.serve("/form", """
            <title>Form</title>
            <script>addEventListener('beforeunload', (e) => { window.asked = true; e.preventDefault(); e.returnValue = 'Stay?'; });</script>
            <button onclick="this.textContent = 'Touched'">Touch</button>
            """)
        let other = try await harness.pages.serve("/other", "<title>Other</title><p>Elsewhere</p>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(form)])
        let touch = try #require(try await ref(of: #"button "Touch""#, agent))
        _ = try await agent.call("click", ["tab": "t1", "ref": .string(touch)])

        let left = try await agent.call("navigate", ["tab": "t1", "url": AgentJSON(other)])

        #expect(!left.isError, "\(left.text)")
        #expect(left.text.contains("Elsewhere"), "\(left.text)")
    }

    /// A window the page opens on the agent's click is an Agent tab of the
    /// same session: listed, readable, not another session's, and in no
    /// window of the owner's. One the page opens between actions joins too.
    @Test func aPopupBelongsToTheSameSession() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let popup = try await harness.pages.serve("/popup", "<title>Popup</title><p>Sign in here</p>")
        let later = try await harness.pages.serve("/later", "<title>Later</title><p>Opened later</p>")
        let url = try await harness.pages.serve("/main", """
            <title>Main</title>
            <button onclick="window.open('\(popup.absoluteString)', 'signin', 'width=400,height=500')">Sign in</button>
            """)
        let agent = try await harness.agent()
        let stranger = try await harness.agent(session: "session-2")
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let signIn = try #require(try await ref(of: #"button "Sign in""#, agent))

        let clicked = try await agent.call("click", ["tab": "t1", "ref": .string(signIn)])

        #expect(clicked.text.contains("opened a new tab t2"), "\(clicked.text)")
        try await waitFor("the popup never loaded") { try await agent.call("text", ["tab": "t2"]).text.contains("Sign in here") }
        #expect(try await stranger.call("text", ["tab": "t2"]).isError)
        let opened = try #require(harness.agents?.tabs.first { $0.url == popup })
        #expect(!Browser.all.contains { !$0.isForAgents && $0.tabs.contains { $0 === opened } })

        // The page opens another by itself, between the agent's actions.
        _ = try await opened.page?.evaluateJavaScript("window.open('\(later.absoluteString)'); 0")
        try await waitFor("the later window isn't the session's") {
            try await agent.call("tabs").text.contains(later.absoluteString)
        }
        #expect(!(try await stranger.call("tabs").text.contains(later.absoluteString)))
    }

    private func ref(of element: String, _ agent: AgentTestClient, tab: String = "t1") async throws -> String? {
        let outline = try await agent.call("snapshot", ["tab": .string(tab)]).text
        return AgentClickTests.ref(of: element, in: outline)
    }
}
