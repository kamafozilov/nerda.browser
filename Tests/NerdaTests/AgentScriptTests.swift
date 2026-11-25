import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents run a short script of many steps in one call, and JavaScript in
/// the page (spec #119, ticket #142): `run` does each step as a normal
/// request in JavaScriptCore inside the shim, at most 200 of them; `eval`
/// runs in a world of its own that never sees a password's value.
@MainActor
struct AgentScriptTests {
    /// A script opens a page, finds a button in its outline, clicks it and
    /// reads the text the click brought: each step a normal request, and
    /// what the script printed and returned is the answer.
    @Test func aScriptOpensClicksAndReadsInSequence() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/offer", """
            <title>Offer</title>
            <button onclick="document.querySelector('#code').textContent = 'Your code is NERDA-42'">Show code</button>
            <p id=code></p>
            """)
        let agent = try await harness.agent()

        let answer = try await agent.call("run", ["script": .string("""
            const opened = open("\(url.absoluteString)");
            print(opened.includes("tab: t1") ? "opened t1" : "no t1");
            const ref = snapshot("t1").match(/(e\\d+) button "Show code"/)[1];
            click("t1", ref);
            const words = text({ tab: "t1" });
            return words.match(/NERDA-\\d+/)[0];
            """)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("opened t1"), "\(answer.text)")
        #expect(answer.text.contains("NERDA-42"), "\(answer.text)")
        #expect(answer.text.contains("4 steps"), "\(answer.text)")
        // The steps were real requests: the tab is the session's.
        let tabs = try await agent.call("tabs")
        #expect(tabs.text.contains("t1"), "\(tabs.text)")
    }

    /// The verbs that type, press, choose, hover, drag and scroll are steps
    /// of a script too, each acting on the page as when called alone.
    @Test func aScriptTypesChoosesHoversDragsAndScrolls() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/form", """
            <title>Form</title>
            <script>window.heard = [];</script>
            <label>Name <input id=who></label>
            <label>Size <select id=size onchange="heard.push('size ' + this.value)">
              <option value=s>Small</option><option value=l>Large</option>
            </select></label>
            <button id=menu onmouseover="heard.push('hovered')">Menu</button>
            <ul><li id=file draggable=true>report.pdf</li></ul>
            <div id=trash role=region aria-label="Trash" style="height: 150px; border: 1px solid">Drop files here</div>
            <div style="height: 3000px"></div>
            <script>
              file.addEventListener('dragstart', (e) => e.dataTransfer.setData('text/plain', 'report.pdf'));
              trash.addEventListener('dragover', (e) => e.preventDefault());
              trash.addEventListener('drop', (e) => { e.preventDefault(); heard.push('dropped ' + e.dataTransfer.getData('text/plain')); });
              who.addEventListener('keydown', (e) => { if (e.key === 'Enter') heard.push('enter'); });
            </script>
            """)
        let agent = try await harness.agent()

        let answer = try await agent.call("run", ["script": .string("""
            open("\(url.absoluteString)");
            const outline = snapshot({ tab: "t1", full: true });
            const ref = (what) => outline.split("\\n").find((line) => line.includes(" " + what)).match(/((?:f\\d+)?e\\d+) /)[1];
            type("t1", ref('textbox "Name"'), "Ada");
            press({ tab: "t1", ref: ref('textbox "Name"'), key: "Enter" });
            choose({ tab: "t1", ref: ref('combobox "Size"'), option: "Large" });
            hover("t1", ref('button "Menu"'));
            drag("t1", ref("listitem"), ref('region "Trash"'));
            scroll({ tab: "t1" });
            return nerda.eval("t1", "return document.querySelector('#who').value");
            """)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("Ada"), "\(answer.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        let heard = try await page.callAsyncJavaScript("return heard", contentWorld: .page) as? [String] ?? []
        #expect(heard.contains("enter"), "\(heard)")
        #expect(heard.contains("size l"), "\(heard)")
        #expect(heard.contains("hovered"), "\(heard)")
        #expect(heard.contains("dropped report.pdf"), "\(heard)")
        #expect(try await page.callAsyncJavaScript("return scrollY", contentWorld: .page) as? Double ?? 0 > 0)
    }

    /// Past 200 steps the script is stopped, with a message that says so,
    /// even when it catches the error; `state` keeps what it had counted
    /// for the next run.
    @Test func aScriptPast200StepsIsStopped() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()

        let stopped = try await agent.call("run", ["script": """
            state.done = 0;
            for (let i = 0; i < 250; i++) {
                try { tabs(); state.done++; } catch (error) { }
            }
            return "finished";
            """])

        #expect(stopped.isError)
        #expect(stopped.text.contains("200 steps"), "\(stopped.text)")
        #expect(!stopped.text.contains("finished"), "\(stopped.text)")

        let next = try await agent.call("run", ["script": "return state.done"])
        #expect(!next.isError, "\(next.text)")
        #expect(next.text.contains("200"), "\(next.text)")
    }

    /// A step that fails stops the script with what failed, unless the
    /// script catches it; what it printed before still comes back.
    @Test func aFailingStepStopsTheScriptWithWhy() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()

        let caught = try await agent.call("run", ["script": """
            try { snapshot("t9"); } catch (error) { return "caught " + error.code; }
            """])
        #expect(!caught.isError, "\(caught.text)")
        #expect(caught.text.contains("caught no_tab"), "\(caught.text)")

        let failed = try await agent.call("run", ["script": """
            print("before");
            snapshot("t9");
            print("after");
            """])
        #expect(failed.isError)
        #expect(failed.text.contains("before"), "\(failed.text)")
        #expect(!failed.text.contains("after"), "\(failed.text)")
        #expect(failed.text.contains("snapshot"), "\(failed.text)")
        #expect(failed.text.contains("t9"), "\(failed.text)")
    }

    /// A script that never ends is stopped, and a long output is cut short.
    @Test func aRunawayScriptAndALongOutputAreBounded() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()

        let looped = try await agent.call("run", ["script": "while (true) {}", "seconds": 1])
        #expect(looped.isError)
        #expect(looped.text.contains("time"), "\(looped.text)")

        let long = try await agent.call("run", ["script": "for (let i = 0; i < 10000; i++) print('line ' + i + ' of a long output')"])
        #expect(!long.isError, "\(long.text)")
        #expect(long.text.count < AgentScript.mostOutput + 500)
        #expect(long.text.contains("left out"), "\(long.text.suffix(300))")
    }

    /// The command line runs scripts too, with the same steps.
    @Test func theCommandLineRunsAScript() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/hello", "<title>Hello</title><p>Hello from the page</p>")
        let shell = ["NERDA_BROWSER_SESSION": "script-run", "TMPDIR": harness.folder.path]

        let ran = await AgentCommandLine.run(
            ["run", "open('\(url.absoluteString)'); state.seen = text('t1').includes('Hello from the page'); return state.seen"],
            environment: shell, socket: harness.socket
        )
        #expect(ran.status == 0, "\(ran.errors)")
        #expect(ran.output.contains("true"), "\(ran.output)")

        let again = await AgentCommandLine.run(["run", "return state.seen"], environment: shell, socket: harness.socket)
        #expect(again.output.contains("true"), "\(again.output) \(again.errors)")
    }

    /// eval runs in the page and answers what it returned, as JSON, even
    /// where the page's own policy forbids its scripts eval.
    @Test func evalAnswersWhatItReturned() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/numbers", """
            <meta http-equiv="Content-Security-Policy" content="script-src 'unsafe-inline'">
            <title>Numbers</title><ul><li>3</li><li>4</li></ul>
            <script>window.secretOfThePage = 'page variable';</script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let answer = try await agent.call("eval", ["tab": "t1", "script": """
            const items = [...document.querySelectorAll('li')].map((li) => Number(li.textContent));
            return { title: document.title, sum: items.reduce((a, b) => a + b), pageVariable: typeof secretOfThePage };
            """])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains(#""sum":7"#), "\(answer.text)")
        #expect(answer.text.contains(#""title":"Numbers""#), "\(answer.text)")
        // Its own world: the page's variables aren't there.
        #expect(answer.text.contains(#""pageVariable":"undefined""#), "\(answer.text)")

        let thrown = try await agent.call("eval", ["tab": "t1", "script": "throw new Error('nothing here')"])
        #expect(thrown.isError)
        #expect(thrown.text.contains("nothing here"), "\(thrown.text)")
    }

    /// eval changing the page answers with what changed, as an action does.
    @Test func evalAnswersWhatItChanged() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/form", "<title>Form</title><button>Send</button>")
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let answer = try await agent.call("eval", ["tab": "t1", "script": """
            const button = document.createElement('button');
            button.textContent = 'Cancel';
            document.body.append(button);
            """])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("came:"), "\(answer.text)")
        #expect(answer.text.contains(#"button "Cancel""#), "\(answer.text)")
    }

    /// No way eval tries reads a password field's value: not the value
    /// itself, not a form's data, not a changed type, not another realm's
    /// getter, not script put in the page's own world.
    @Test func evalCantReadAPasswordsValue() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/login", """
            <title>Sign in</title>
            <form id=login><input name=user value=ann><input type=password name=pass id=pass></form>
            <iframe id=same srcdoc="<p>frame</p>"></iframe>
            <script>document.querySelector('#pass').value = 'hunter2';</script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let pass = "document.querySelector('#pass')"

        let attempts = [
            "return \(pass).value",
            "return [...new FormData(document.querySelector('#login')).entries()]",
            "\(pass).type = 'text'; return \(pass).value",
            "\(pass).setAttribute('type', 'text'); return \(pass).value",
            "\(pass).attributes.type.value = 'text'; return \(pass).value",
            "const copy = \(pass).cloneNode(); copy.removeAttribute('type'); return copy.value",
            """
            const other = document.querySelector('#same').contentWindow;
            return Object.getOwnPropertyDescriptor(other.HTMLInputElement.prototype, 'value').get.call(\(pass))
            """,
            """
            const frame = document.createElement('iframe');
            document.body.append(frame);
            return Object.getOwnPropertyDescriptor(frame.contentWindow.HTMLInputElement.prototype, 'value').get.call(\(pass))
            """,
            """
            const script = document.createElement('script');
            script.textContent = "document.body.dataset.leak = document.querySelector('#pass').value";
            document.body.append(script);
            await new Promise((resolve) => setTimeout(resolve, 100));
            return document.body.dataset.leak
            """,
            """
            document.body.insertAdjacentHTML('beforeend', `<img src=x onerror="document.body.dataset.leak = document.querySelector('#pass').value">`);
            await new Promise((resolve) => setTimeout(resolve, 300));
            return document.body.dataset.leak
            """,
            """
            const image = document.createElement('img');
            image.setAttribute('onerror', "document.body.dataset.leak = document.querySelector('#pass').value");
            image.src = 'x';
            document.body.append(image);
            await new Promise((resolve) => setTimeout(resolve, 300));
            return document.body.dataset.leak
            """,
            "Object.defineProperty(HTMLInputElement.prototype, 'value', { get() { return 'undone' } }); return \(pass).value",
            "\(pass).focus(); \(pass).select(); return getSelection().toString()",
            """
            const form = document.querySelector('#login');
            let seen = null;
            form.addEventListener('formdata', (event) => { seen = [...event.formData.entries()]; });
            new FormData(form);
            return seen
            """,
            "document.querySelector('#login').submit(); await new Promise((r) => setTimeout(r, 300)); return location.href",
            "\(pass).form.method = 'get'; return 'changed'",
            "const frame = document.createElement('iframe'); frame.srcdoc = '<script>parent.document.body.dataset.leak = parent.document.querySelector(\"#pass\").value<\\/script>'; document.body.append(frame); await new Promise((r) => setTimeout(r, 300)); return document.body.dataset.leak",
        ]
        for attempt in attempts {
            let answer = try await agent.call("eval", ["tab": "t1", "script": .string(attempt)])
            #expect(!answer.text.contains("hunter2"), "\(attempt)\n→ \(answer.text)")
        }
        // A form's data reaches a formdata listener masked, and a form
        // with a password isn't sent as a GET from eval.
        let data = try await agent.call("eval", ["tab": "t1", "script": """
            const form = document.querySelector('#login');
            let seen = null;
            form.addEventListener('formdata', (event) => { seen = [...event.formData.entries()]; });
            new FormData(form);
            return seen
            """])
        #expect(data.text.contains(#"["pass","••••"]"#), "\(data.text)")
        let sent = try await agent.call("eval", ["tab": "t1", "script": "document.querySelector('#login').submit()"])
        #expect(sent.isError, "\(sent.text)")
        // The value still reads as masked, and is still there for the page.
        let masked = try await agent.call("eval", ["tab": "t1", "script": .string("return \(pass).value")])
        #expect(masked.text.contains("••••"), "\(masked.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        let value = try await page.callAsyncJavaScript("return document.querySelector('#pass').value", contentWorld: .page) as? String
        #expect(value == "hunter2")
        let leak = try await page.callAsyncJavaScript("return document.body.dataset.leak ?? ''", contentWorld: .page) as? String
        #expect(leak == "")
    }
}
