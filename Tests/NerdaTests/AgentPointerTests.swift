import Foundation
import Testing
import WebKit
@testable import Nerda

/// Agents hover, drag and scroll (spec #119, ticket #138), in Agent tabs
/// that are never on screen, and each answer says what it changed.
@MainActor
struct AgentPointerTests {
    /// A menu that only shows while the pointer is over its heading opens
    /// on hover, and its items can then be clicked.
    @Test func hoverRevealsAHoverOnlyMenu() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let laptops = try await harness.pages.serve("/laptops", "<title>Laptops</title><p>All our laptops</p>")
        let url = try await harness.pages.serve("/shop", """
            <title>Shop</title>
            <style>
              #menu { display: none }
              #products:hover #menu { display: block }
            </style>
            <div style="height: 1500px"></div>
            <nav><div id=products><span tabindex=0 role=button>Products</span>
              <div id=menu><a href="\(laptops.path)">Laptops</a></div>
            </div></nav>
            <div style="height: 1500px"></div>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        #expect(!outline.contains("Laptops"), "\(outline)")
        let products = try #require(AgentClickTests.ref(of: #"button "Products""#, in: outline), "\(outline)")

        let answer = try await agent.call("hover", ["tab": "t1", "ref": .string(products)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.hasPrefix(#"hovered \#(products) button "Products""#), "\(answer.text)")
        let came = try #require(section("came", of: answer.text), "\(answer.text)")
        let menuItem = try #require(came.first { $0.contains(#"link "Laptops""#) }, "\(answer.text)")
        let item = try #require(AgentClickTests.ref(of: #"link "Laptops""#, in: menuItem))

        let clicked = try await agent.call("click", ["tab": "t1", "ref": .string(item)])

        #expect(!clicked.isError, "\(clicked.text)")
        #expect(clicked.text.contains("All our laptops"), "\(clicked.text)")
    }

    /// Menus the page's own script opens when the pointer comes over their
    /// heading, and closes when it leaves: hovering one opens it, and
    /// hovering the next closes it again.
    @Test func hoveringElsewhereClosesAScriptsMenu() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/menus", """
            <title>Menus</title>
            <div class=menu><button>File</button><div hidden><a href="#new">New file</a></div></div>
            <div class=menu><button>Edit</button><div hidden><a href="#undo">Undo</a></div></div>
            <script>
              for (const menu of document.querySelectorAll('.menu')) {
                menu.addEventListener('mouseenter', () => menu.lastElementChild.hidden = false);
                menu.addEventListener('mouseleave', () => menu.lastElementChild.hidden = true);
              }
            </script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        let file = try #require(AgentClickTests.ref(of: #"button "File""#, in: outline), "\(outline)")
        let edit = try #require(AgentClickTests.ref(of: #"button "Edit""#, in: outline), "\(outline)")

        let onFile = try await agent.call("hover", ["tab": "t1", "ref": .string(file)]).text
        let fileCame = try #require(section("came", of: onFile), "\(onFile)")
        #expect(fileCame.count == 1 && fileCame[0].contains(#"link "New file""#), "\(onFile)")

        let onEdit = try await agent.call("hover", ["tab": "t1", "ref": .string(edit)]).text
        let editCame = try #require(section("came", of: onEdit), "\(onEdit)")
        let editWent = try #require(section("went", of: onEdit), "\(onEdit)")
        #expect(editCame.count == 1 && editCame[0].contains(#"link "Undo""#), "\(onEdit)")
        #expect(editWent.count == 1 && editWent[0].contains(#"link "New file""#), "\(onEdit)")
    }

    /// A card the page moves with the mouse's own presses and moves (as
    /// sortable lists and boards do) is dragged into another column by a
    /// series of moves, and the answer says where it is now.
    @Test func dragMovesACardWithTheMouse() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/board", """
            <title>Board</title>
            <section aria-label="To do"><div id=card role=button tabindex=0>Write report</div></section>
            <section id=done aria-label="Done" style="height: 200px; margin-top: 300px; border: 1px solid"></section>
            <script>
              window.moves = 0;
              let dragging = false;
              card.addEventListener('mousedown', () => dragging = true);
              document.addEventListener('mousemove', (e) => {
                if (!dragging || !e.isTrusted) return;
                moves++;
                Object.assign(card.style, { position: 'fixed', left: e.clientX + 'px', top: e.clientY + 'px', pointerEvents: 'none' });
              });
              document.addEventListener('mouseup', (e) => {
                if (!dragging) return;
                dragging = false;
                card.style.cssText = '';
                if (document.elementFromPoint(e.clientX, e.clientY)?.closest('#done')) done.append(card);
              });
            </script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1", "full": true]).text
        let card = try #require(AgentClickTests.ref(of: #"button "Write report""#, in: outline), "\(outline)")
        let done = try #require(AgentClickTests.ref(of: #"region "Done""#, in: outline), "\(outline)")

        let answer = try await agent.call("drag", ["tab": "t1", "ref": .string(card), "to": .string(done)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.hasPrefix(#"dragged \#(card) button "Write report" to \#(done) region "Done""#), "\(answer.text)")
        #expect(answer.text.contains(#"\#(card) is now in \#(done) region "Done""#), "\(answer.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        #expect(try await page.callAsyncJavaScript("return card.parentElement.id", contentWorld: .page) as? String == "done")
        #expect(try await page.callAsyncJavaScript("return moves", contentWorld: .page) as? Int ?? 0 >= 5)
    }

    /// An element the page drags with the browser's drag and drop
    /// (`draggable`, `dragstart`, `drop`) lands on its target, the data the
    /// page gave it arriving with it, and no drag of the Mac's own starts.
    @Test func dragDropsADraggableElementOnItsTarget() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/files", """
            <title>Files</title>
            <ul><li id=file draggable=true>report.pdf</li></ul>
            <div id=trash role=region aria-label="Trash" style="height: 150px; border: 1px solid">Drop files here</div>
            <script>
              window.log = [];
              file.addEventListener('dragstart', (e) => e.dataTransfer.setData('text/plain', 'report.pdf'));
              trash.addEventListener('dragover', (e) => e.preventDefault());
              trash.addEventListener('drop', (e) => {
                e.preventDefault();
                log.push('dropped ' + e.dataTransfer.getData('text/plain'));
                trash.append(file);
              });
            </script>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1", "full": true]).text
        let file = try #require(AgentClickTests.ref(of: #"listitem"#, in: outline), "\(outline)")
        let trash = try #require(AgentClickTests.ref(of: #"region "Trash""#, in: outline), "\(outline)")

        let answer = try await agent.call("drag", ["tab": "t1", "ref": .string(file), "to": .string(trash)])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains(#"\#(file) is now in \#(trash) region "Trash""#), "\(answer.text)")
        #expect(answer.text.contains("notice: the page drags \(file) with the browser's drag and drop"), "\(answer.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        #expect(try await page.callAsyncJavaScript("return log", contentWorld: .page) as? [String] == ["dropped report.pdf"])
    }

    /// Scrolling the page moves it down by most of a screen, and the answer
    /// lists what came into view, not what was in view already; scrolling
    /// further than the page goes stops at its bottom.
    @Test func scrollMovesThePageAndListsWhatCameIntoView() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let url = try await harness.pages.serve("/long", """
            <title>Long</title>
            <style>body { margin: 0 } div { height: 1000px }</style>
            <button>Top</button>
            <div></div>
            <button>Middle</button>
            <div></div>
            <button>Bottom</button>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])

        let down = try await agent.call("scroll", ["tab": "t1"])

        #expect(!down.isError, "\(down.text)")
        #expect(down.text.hasPrefix("scrolled the page down"), "\(down.text)")
        let seen = try #require(section("now in view", of: down.text), "\(down.text)")
        #expect(seen.count == 1 && seen[0].contains(#"button "Middle""#), "\(down.text)")

        let further = try await agent.call("scroll", ["tab": "t1", "direction": "down", "amount": 5000])

        #expect(further.text.contains("to its bottom"), "\(further.text)")
        let then = try #require(section("now in view", of: further.text), "\(further.text)")
        #expect(then.count == 1 && then[0].contains(#"button "Bottom""#), "\(further.text)")

        let again = try await agent.call("scroll", ["tab": "t1", "direction": "down"])
        #expect(again.text.hasPrefix("the page is at its bottom already"), "\(again.text)")
    }

    /// Given an element in a box that scrolls on its own (a list of
    /// messages), scroll moves that box rather than the page, and lists
    /// what came into view in it.
    @Test func scrollMovesTheBoxHoldingAnElement() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let messages = (1...30).map { "<p style=\"margin: 0; height: 40px\"><a href=\"#m\($0)\">Message \($0)</a></p>" }.joined()
        let url = try await harness.pages.serve("/inbox", """
            <title>Inbox</title>
            <div style="height: 200px; overflow: auto">\(messages)</div>
            <button>Compose</button>
            <div style="height: 3000px"></div>
            """)
        let agent = try await harness.agent()
        _ = try await agent.call("open", ["url": AgentJSON(url)])
        let outline = try await agent.call("snapshot", ["tab": "t1"]).text
        let first = try #require(AgentClickTests.ref(of: #"link "Message 1""#, in: outline), "\(outline)")

        let answer = try await agent.call("scroll", ["tab": "t1", "ref": .string(first), "amount": 200])

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.hasPrefix(#"scrolled the box holding \#(first) link "Message 1" down 200 px"#), "\(answer.text)")
        let seen = try #require(section("now in view", of: answer.text), "\(answer.text)")
        #expect(seen.map { $0.firstMatch(of: /"(Message \d+)"/).map { String($0.output.1) } ?? $0 }
            == (6...10).map { "Message \($0)" }, "\(answer.text)")
        let page = try #require(harness.agents?.tabs.first?.page)
        #expect(try await page.callAsyncJavaScript("return scrollY", contentWorld: .page) as? Int == 0)
    }

    // MARK: - Helpers

    /// The lines under `came:`, `went:` or `changed:` in an answer.
    private func section(_ name: String, of answer: String) -> [String]? {
        let lines = answer.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(of: name + ":") else { return nil }
        return Array(lines[(start + 1)...].prefix { $0.hasPrefix("- ") })
    }
}
