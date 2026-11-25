import Foundation
import WebKit

/// Acting on a page's elements by their refs, with real input, each action
/// answered with what it changed (`AgentPage.act`).
nonisolated extension AgentVerb {
    static let actingVerbs: [AgentVerb] = [click]

    static let click = AgentVerb(
        name: "click",
        summary: """
            Click an element of an Agent tab's page by its ref, as a person would: scrolled into view, \
            then the mouse's own click. An element covered by another (a cookie banner, a dialog) isn't \
            clicked: the answer names the covering element's buttons, to close it first. Waits for the page \
            to settle, then answers with what came, went or changed, by ref, or the new page after a \
            navigation, and says when a new tab opened or a dialog came up.
            """,
        arguments: [.tab, .string("ref", "The element to click, as snapshot named it, such as e12")]
    ) { call in
        let tab = try call.tab()
        let ref = try call.string("ref")
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.click(ref, in: tab)
        }
    }
}

extension AgentPage {
    /// Clicks the element `ref` names as a person would: scrolled into view,
    /// checked to be on top where the click goes, then the mouse's own
    /// events (`AgentInput`). Should no trusted click reach it (the page
    /// takes no mouse there), it is clicked by script instead, and a notice
    /// says so. Answers the action's line for `act`.
    static func click(_ ref: String, in agentTab: AgentTab) async throws -> String {
        let aim = try await aim(ref, in: agentTab, watchingClicks: true)
        let element = aim.element, what = aim.what
        try AgentInput.click(element.page, at: aim.point)

        // Whether the page heard it: gone (a navigation, the element taken
        // away) or held by a dialog counts as heard.
        let heard = await unlessHeld(agentTab.tab, by: .now + .seconds(1)) {
            try await element.page.callAsyncJavaScript(
                AgentPageScript.source + "\n" + heardScript, arguments: ["op": "run", "args": [String: Any](), "prefix": ""],
                in: element.frame, contentWorld: world
            ) as? Bool
        }
        if heard == false {
            _ = await unlessHeld(agentTab.tab, by: .now + .seconds(1)) {
                try await run("element.click(); return true", on: element)
            }
            AgentNotices.post("the page took no mouse click on \(ref), so Nerda clicked it by script", on: agentTab.tab)
        }
        return "clicked \(what)"
    }

    /// Where the pointer goes to reach the element `ref` names, as a person
    /// would: the element scrolled into view (`scrolling` as
    /// `scrollIntoView`'s block and inline), a point of it checked to be on
    /// top, in its page view's points from the top left. Also the point in
    /// the element's own frame (`inFrame`, CSS px), and how to name it.
    /// Fails when it isn't shown, or another element covers it (`covered`,
    /// naming that one's buttons; `action` is what would land there).
    /// `watchingClicks` arms a listener for the click to come (`heardScript`).
    static func aim(_ ref: String, in agentTab: AgentTab, for action: String = "click", scrolling: String = "center",
                    watchingClicks: Bool = false) async throws -> (element: AgentElement, point: CGPoint, inFrame: CGPoint, what: String) {
        let element = try await element(ref, in: agentTab)
        let aim = try await run(clickHelpers + aimScript, on: element, arguments: ["scrolling": scrolling, "watching": watchingClicks]) as? [String: Any] ?? [:]
        let what = describe(ref: ref, aim["what"])
        if aim["unseen"] != nil {
            throw AgentError(.failed, "\(what) isn't shown on the page (no size, or out of reach), so it can't be \(action == "click" ? "clicked" : "reached").")
        }
        if let cover = aim["covered"] { throw covered(what, by: cover, action: action) }
        guard let x = aim["x"] as? Double, let y = aim["y"] as? Double else {
            throw AgentError(.failed, "Nerda couldn't find where \(what) is on the page.")
        }
        let inFrame = CGPoint(x: x, y: y)
        var point = inFrame
        // Into the page's own coordinates, frame by frame, from a frame of
        // another site up through those holding it.
        if let path = aim["path"] as? [Int], !path.isEmpty {
            let tree = await frames(of: element.page)
            for depth in stride(from: path.count - 1, through: 0, by: -1) {
                let holder = depth == 0 ? nil : tree?.frame(at: Array(path[..<depth]))?.info
                guard depth == 0 || holder != nil else { throw AgentError(.failed, "Nerda couldn't find where \(what) is on the page.") }
                let step = try await element.page.callAsyncJavaScript(
                    AgentPageScript.source + "\n" + clickHelpers + holderScript,
                    arguments: ["op": "run", "args": [String: Any](), "prefix": "", "index": path[depth], "x": point.x, "y": point.y],
                    in: holder, contentWorld: world
                ) as? [String: Any] ?? [:]
                if let cover = step["covered"] { throw covered(what, by: cover, action: action) }
                guard let x = step["x"] as? Double, let y = step["y"] as? Double else {
                    throw AgentError(.failed, "Nerda couldn't find where \(what) is on the page.")
                }
                point = CGPoint(x: x, y: y)
            }
        }
        let zoom = element.page.pageZoom * element.page.magnification
        return (element, CGPoint(x: point.x * zoom, y: point.y * zoom), inFrame, what)
    }

    /// `e7 button "Send"`, from the page model's description of an element.
    static func describe(ref: String?, _ description: Any?) -> String {
        let description = description as? [String: Any] ?? [:]
        var words = [ref ?? description["ref"] as? String, description["role"] as? String].compactMap(\.self)
        if let name = description["name"] as? String, !name.isEmpty {
            words.append(String(reflecting: String(name.prefix(80))))
        } else if let text = description["text"] as? String, !text.isEmpty {
            words.append(String(reflecting: text))
        }
        return words.joined(separator: " ")
    }

    private static func covered(_ what: String, by cover: Any, action: String) -> AgentError {
        let cover = cover as? [String: Any] ?? [:]
        let layer = describe(ref: nil, cover["layer"])
        let buttons = (cover["buttons"] as? [Any] ?? []).map { describe(ref: nil, $0) }
        var message = "\(what) is covered by \(layer), so a \(action) there would land on that instead."
        message += buttons.isEmpty
            ? " Close it or scroll it away, then \(action) \(what.split(separator: " ").first ?? "") again."
            : " Its buttons: \(buttons.joined(separator: ", ")). Close it with one of them, then \(action) again."
        return AgentError(.covered, message)
    }

    /// Script helpers for finding what is on top at a point, and what a
    /// covering layer offers to close it. Run in the page model's world.
    private static let clickHelpers = """
        const up = (node) => node.parentElement || node.parentNode?.host || null;
        /// The element on top at a point of a document, down open shadow roots.
        const topAt = (root, x, y) => {
            let found = root.elementFromPoint(x, y);
            while (found?.shadowRoot) {
                const inner = found.shadowRoot.elementFromPoint(x, y);
                if (!inner || inner === found) break;
                found = inner;
            }
            return found;
        };
        /// Whether a click on `found` is a click on `element`: it is the
        /// element, in it, or in one of its labels.
        const reaches = (element, found) => {
            for (let node = found; node; node = up(node)) if (node === element) return true;
            return [...(element.labels || [])].some((label) => label.contains(found));
        };
        /// The layer `found` is part of (the outermost fixed, sticky or
        /// absolute box, or dialog, around it that doesn't hold `element`),
        /// and the buttons in it.
        const covering = (found, element) => {
            if (!found) return { layer: { text: 'something' }, buttons: [] };
            let layer = found;
            for (let node = found; node && node !== node.ownerDocument.body && node !== node.ownerDocument.documentElement; node = up(node)) {
                if (reaches(node, element)) break;
                const style = node.ownerDocument.defaultView.getComputedStyle(node);
                if (['fixed', 'sticky', 'absolute'].includes(style.position) || node.localName === 'dialog'
                    || /dialog/.test(node.getAttribute('role') || '')) layer = node;
            }
            const buttons = [];
            const walk = (root) => {
                for (const child of root.children || []) {
                    if (buttons.length >= 8) return;
                    const described = nerdaAgent.describe(child);
                    if (!described.shown) continue;
                    if (['button', 'link', 'clickable', 'checkbox', 'switch', 'menuitem'].includes(described.role)) {
                        if (described.name) buttons.push(described);
                        continue;
                    }
                    walk(child.shadowRoot || child);
                }
            };
            walk(layer.shadowRoot || layer);
            return { layer: nerdaAgent.describe(layer), buttons };
        };

        """

    /// Scrolls `element` into view, finds a point of it that is on top, and
    /// with `watching` arms a listener for its click. Answers `{x, y, path, what}` (the point
    /// in this frame, the frame's path down from the top window), or
    /// `{unseen}`, or `{covered: {layer, buttons}}`.
    private static let aimScript = """
        const what = nerdaAgent.describe(element);
        const view = element.ownerDocument.defaultView;
        element.scrollIntoView({ block: scrolling, inline: scrolling, behavior: 'instant' });
        const boxes = [...element.getClientRects()].filter((box) => box.width > 0 && box.height > 0);
        const box = boxes.find((box) => box.bottom > 0 && box.right > 0 && box.top < view.innerHeight && box.left < view.innerWidth);
        if (!box) return { unseen: true, what };
        const left = Math.max(box.left, 0), right = Math.min(box.right, view.innerWidth);
        const top = Math.max(box.top, 0), bottom = Math.min(box.bottom, view.innerHeight);
        let at = null, cover = null;
        for (const [across, down] of [[0.5, 0.5], [0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]]) {
            const x = left + (right - left) * across, y = top + (bottom - top) * down;
            const found = topAt(element.ownerDocument, x, y);
            if (reaches(element, found)) { at = [x, y]; break; }
            cover = cover || found;
        }
        if (!at) return { covered: covering(cover, element), what };
        // Up through frames of this one's site, to this frame's coordinates.
        let [x, y] = at;
        for (let inner = view; inner !== window; inner = inner.parent) {
            const holder = inner.frameElement;
            const outer = holder.getBoundingClientRect();
            const style = inner.parent.getComputedStyle(holder);
            x += outer.left + holder.clientLeft + parseFloat(style.paddingLeft);
            y += outer.top + holder.clientTop + parseFloat(style.paddingTop);
            const found = topAt(inner.parent.document, x, y);
            if (found !== holder) return { covered: covering(found, holder), what };
        }
        const path = [];
        for (let frame = window; frame !== frame.top; frame = frame.parent) {
            let index = -1;
            for (let i = 0; i < frame.parent.frames.length; i++) if (frame.parent.frames[i] === frame) { index = i; break; }
            path.unshift(index);
        }
        if (watching) {
            const watch = { trusted: false };
            watch.listener = (event) => { if (event.isTrusted && reaches(element, event.composedPath()[0])) watch.trusted = true; };
            element.ownerDocument.addEventListener('click', watch.listener, true);
            watch.document = element.ownerDocument;
            nerdaAgent.clickWatch = watch;
        }
        return { x, y, path, what };
        """

    /// In a frame holding the clicked one (`frames[index]`), from the point
    /// `x, y` in that one: the point in this frame, scrolled into view and
    /// checked to be on the holding frame, or `{covered}`.
    private static let holderScript = """
        const child = frames[index];
        let holder = null;
        const find = (root) => {
            for (const candidate of root.querySelectorAll('iframe, frame')) if (candidate.contentWindow === child) holder = candidate;
            for (const host of root.querySelectorAll('*')) if (!holder && host.shadowRoot) find(host.shadowRoot);
        };
        find(document);
        if (!holder) return {};
        const place = () => {
            const outer = holder.getBoundingClientRect();
            const style = holder.ownerDocument.defaultView.getComputedStyle(holder);
            return [x + outer.left + holder.clientLeft + parseFloat(style.paddingLeft), y + outer.top + holder.clientTop + parseFloat(style.paddingTop)];
        };
        const view = holder.ownerDocument.defaultView;
        let [px, py] = place();
        if (px < 0 || py < 0 || px > view.innerWidth || py > view.innerHeight) {
            view.scrollBy(px < 0 || px > view.innerWidth ? px - view.innerWidth / 2 : 0, py < 0 || py > view.innerHeight ? py - view.innerHeight / 2 : 0);
            [px, py] = place();
        }
        const found = topAt(holder.ownerDocument, px, py);
        if (found !== holder) return { covered: covering(found, holder) };
        for (let inner = view; inner !== window; inner = inner.parent) {
            const outer = inner.frameElement.getBoundingClientRect();
            px += outer.left + inner.frameElement.clientLeft;
            py += outer.top + inner.frameElement.clientTop;
        }
        return { x: px, y: py };
        """

    /// Whether the armed click arrived trusted, waiting a little for it;
    /// the listener let go of either way. True when nothing was armed.
    private static let heardScript = """
        const watch = nerdaAgent.clickWatch;
        if (!watch) return true;
        const until = Date.now() + 500;
        while (!watch.trusted && Date.now() < until) await new Promise((done) => setTimeout(done, 20));
        watch.document.removeEventListener('click', watch.listener, true);
        nerdaAgent.clickWatch = null;
        return watch.trusted;
        """
}
