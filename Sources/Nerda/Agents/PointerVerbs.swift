import Foundation
import WebKit

/// The pointer's other work besides clicks: hovering over an element,
/// dragging one to another, and scrolling the page or a box in it. Each is
/// answered with what it changed (`AgentPage.act`).
nonisolated extension AgentVerb {
    static let pointerVerbs: [AgentVerb] = [hover, drag, scroll]

    static let hover = AgentVerb(
        name: "hover",
        summary: """
            Move the pointer over an element of an Agent tab's page by its ref, as a person would, to open \
            a menu or show what only shows while the pointer is there. It stays there until the pointer goes \
            elsewhere, so a menu it opened can then be clicked. Answers with what came, went or changed.
            """,
        arguments: [.tab, .string("ref", "The element to move the pointer over, as snapshot named it, such as e12")]
    ) { call in
        let tab = try call.tab()
        let ref = try call.string("ref")
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.hover(ref, in: tab)
        }
    }

    static let drag = AgentVerb(
        name: "drag",
        summary: """
            Drag an element of an Agent tab's page onto another, by their refs, as a person would: pressed, \
            moved there in a series of moves, and let go (cards on a board, items in a sortable list, files \
            onto a drop area). Both are brought into view first. Answers with where the dragged element is \
            now, and what came, went or changed.
            """,
        arguments: [
            .tab,
            .string("ref", "The element to drag, as snapshot named it, such as e12"),
            .string("to", "The element to drop it on, such as e15"),
        ]
    ) { call in
        let tab = try call.tab()
        let ref = try call.string("ref")
        let target = try call.string("to")
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.drag(ref, to: target, in: tab)
        }
    }

    static let scroll = AgentVerb(
        name: "scroll",
        summary: """
            Scroll an Agent tab's page, or with ref the box that scrolls on its own holding that element \
            (a list, a chat, a side panel), by most of a screen or by amount. Answers with how far it went \
            and what more there is, the elements that came into view, and what came, went or changed (a \
            page that loads more as it is scrolled).
            """,
        arguments: [
            .tab,
            .string("ref", "An element in the box to scroll, or the box itself, such as e12; the page when left out", required: false),
            AgentArgument(name: "direction", schema: [
                "type": "string", "enum": ["down", "up", "right", "left"], "description": "Which way: down (the default), up, right or left",
            ], required: false),
            .integer("amount", "How far, in the page's pixels: most of what shows of it when left out"),
        ]
    ) { call in
        let tab = try call.tab()
        let ref = call.optionalString("ref").flatMap { $0.isEmpty ? nil : $0 }
        let direction = call.optionalString("direction") ?? "down"
        guard ["down", "up", "right", "left"].contains(direction) else {
            throw AgentError(.invalid, "Give direction as down, up, right or left.")
        }
        var amount: Double?
        if let given = call.arguments["amount"] {
            guard let number = given.number, number > 0 else { throw AgentError(.invalid, "Give amount as a number of pixels above 0.") }
            amount = number
        }
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.scroll(ref, direction, by: amount, in: tab)
        }
    }
}

extension AgentPage {
    /// Drags the element `ref` names onto the one `target` names, with the
    /// mouse's own press, moves and release (`AgentInput.drag`), both
    /// brought into view together first. Answers the action's line, and
    /// where the element is now when that changed.
    static func drag(_ ref: String, to target: String, in agentTab: AgentTab) async throws -> String {
        // Both in view: each scrolled to only as far as it takes, and the
        // first checked again, so neither is left out by the other's scroll.
        _ = try await aim(ref, in: agentTab, for: "drag", scrolling: "nearest")
        let end = try await aim(target, in: agentTab, for: "drag", scrolling: "nearest")
        let start = try await aim(ref, in: agentTab, for: "drag", scrolling: "nearest")
        guard try await aim(target, in: agentTab, for: "drag", scrolling: "nearest").point == end.point else {
            throw AgentError(.failed, "\(start.what) and \(end.what) are too far apart to show at once, so one can't be dragged onto the other.")
        }
        let page = start.element.page
        _ = try await run(placeScript + guardScript, on: start.element)
        do {
            try await AgentInput.drag(page, from: start.point, to: end.point)
        } catch {
            _ = try? await run(dropScript, on: start.element, arguments: ["to": "", "point": [String: Any]()])
            throw error
        }

        // A drag of the browser's own drag and drop was stopped before the
        // Mac's began (`guardScript`): it is done by script instead.
        let script = await unlessHeld(agentTab.tab, by: .now + .seconds(2)) {
            try await run(dropScript, on: start.element, arguments: ["to": target, "point": ["x": end.inFrame.x, "y": end.inFrame.y]]) as? [String: Any]
        } ?? nil
        var line = "dragged \(start.what) to \(end.what)"
        if script?["otherFrame"] != nil {
            throw AgentError(.failed, "The page drags \(start.what) with the browser's drag and drop, which Nerda can only do within one frame, and \(end.what) is in another.")
        }
        if let dropped = script?["dropped"] as? Bool {
            AgentNotices.post("the page drags \(ref) with the browser's drag and drop, so Nerda dragged it by script", on: agentTab.tab)
            if !dropped { line += "\n\(end.what) didn't take the drop" }
        }

        let moved = await unlessHeld(agentTab.tab, by: .now + .seconds(2)) {
            try await run(placeScript + """
                const before = nerdaAgent.dragFrom;
                nerdaAgent.dragFrom = null;
                const now = place(element);
                return before && now.node !== before.node ? now.described : null;
                """, on: start.element) as? [String: Any]
        }
        if let moved { line += "\n\(ref) is now in \(describe(ref: nil, moved))" }
        return line
    }

    /// Before a drag: notes where the element is (`place`), and stops a
    /// drag of the browser's own drag and drop from starting one of the
    /// Mac's, which would follow the owner's pointer rather than the
    /// agent's, noting that it began.
    private static let guardScript = """
        nerdaAgent.dragFrom = place(element);
        const view = element.ownerDocument.defaultView;
        const guard = { view, started: false };
        guard.listener = (event) => {
            if (!event.isTrusted) return;
            event.preventDefault();
            guard.started = true;
        };
        view.addEventListener('dragstart', guard.listener, true);
        nerdaAgent.dragGuard = guard;
        return true;
        """

    /// After a drag: lets go of the guard, and if the page began a drag and
    /// drop, does it by script from `element` to the element `to` names, at
    /// `point` of it: dragstart (the page fills in its data), drag,
    /// dragenter and dragover where the pointer lands, drop if the page
    /// takes it there, and dragend. Answers `{dropped}`, `{otherFrame}`, or
    /// nothing when no drag and drop began.
    private static let dropScript = """
        const guard = nerdaAgent.dragGuard;
        nerdaAgent.dragGuard = null;
        if (!guard) return {};
        guard.view.removeEventListener('dragstart', guard.listener, true);
        if (!guard.started || !to) return {};
        const target = nerdaAgent.element(to);
        if (!target || target.ownerDocument !== element.ownerDocument) return { otherFrame: true };
        const data = new DataTransfer();
        const view = element.ownerDocument.defaultView;
        const box = element.getBoundingClientRect();
        const from = { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
        const at = { clientX: point.x, clientY: point.y };
        const fire = (node, type, place) => {
            const event = new DragEvent(type, { bubbles: true, cancelable: true, composed: true, view, dataTransfer: data, ...place });
            node.dispatchEvent(event);
            return event;
        };
        if (fire(element, 'dragstart', from).defaultPrevented) return { dropped: false };
        fire(element, 'drag', from);
        let over = element.ownerDocument.elementFromPoint(point.x, point.y);
        if (!over || !target.contains(over)) over = target;
        fire(over, 'dragenter', at);
        const taken = fire(over, 'dragover', at).defaultPrevented;
        if (taken) fire(over, 'drop', at);
        else fire(over, 'dragleave', at);
        fire(element, 'dragend', at);
        return { dropped: taken };
        """

    /// `place(element)`: what holds an element, as an agent would know it:
    /// the nearest element around it with a ref, or else with a role.
    private static let placeScript = """
        const place = (element) => {
            let fallback = null;
            for (let node = element.parentElement || element.parentNode?.host; node; node = node.parentElement || node.parentNode?.host) {
                const described = nerdaAgent.describe(node);
                if (described.ref) return { node, described };
                if (!fallback && described.role) fallback = { node, described };
            }
            return fallback || { node: null, described: null };
        };

        """

    /// Moves the pointer over the element `ref` names: scrolled into view,
    /// checked to be on top, then the pointer's own move there. A page whose
    /// window is off screen may not take the move as the pointer being over
    /// the element; then its hover styles are shown by script, and the
    /// page's own pointer events sent to it (`fakeHoverScript`), with a
    /// notice saying so.
    static func hover(_ ref: String, in agentTab: AgentTab) async throws -> String {
        let aim = try await aim(ref, in: agentTab, for: "hover")
        try AgentInput.move(aim.element.page, to: aim.point)
        let faked = await unlessHeld(agentTab.tab, by: .now + .seconds(2)) {
            try await run(fakeHoverScript, on: aim.element, arguments: ["x": aim.inFrame.x, "y": aim.inFrame.y]) as? Bool
        }
        if faked == true {
            AgentNotices.post("the page took no pointer move over \(ref), so Nerda showed its hover styles and sent its pointer events by script", on: agentTab.tab)
        }
        return "hovered \(aim.what)"
    }

    /// In the element's frame, after the pointer's move to `x, y` there:
    /// waits a little for the element to be hovered, and if it isn't, makes
    /// it look and act hovered. Every `:hover` rule the frame's style sheets
    /// (and those of the shadow roots around the element) can be read for
    /// is copied with `[data-nerda-hover]` in its place, and the element and
    /// all around it get that mark, as `:hover` matches them; then the
    /// pointer events a move over it fires (over, enter, move) are sent to
    /// it, and leave and out to what an earlier one hovered. Answers whether
    /// it had to. An earlier hover made this way is undone either way.
    private static let fakeHoverScript = """
        const mark = 'data-nerda-hover';
        const up = (node) => node.parentElement || node.parentNode?.host || null;
        const chainOf = (node) => { const chain = []; for (let at = node; at; at = up(at)) chain.push(at); return chain; };
        const state = nerdaAgent.hover || (nerdaAgent.hover = { chain: [], sheets: [] });
        const before = state.chain.map((held) => held.deref()).filter((node) => node && node.isConnected);
        for (const node of before) node.removeAttribute(mark);
        for (const { root, sheet } of state.sheets) {
            const holder = root.deref();
            if (holder) holder.adoptedStyleSheets = holder.adoptedStyleSheets.filter((one) => one !== sheet);
        }
        state.chain = [];
        state.sheets = [];

        const until = Date.now() + 300;
        while (!element.matches(':hover') && Date.now() < until) await new Promise((done) => setTimeout(done, 20));
        if (element.matches(':hover')) return false;

        // Style sheets: the document's, and each shadow root's the element is in.
        const roots = [element.ownerDocument];
        for (let node = element; node; node = up(node)) {
            const root = node.getRootNode();
            if (root instanceof ShadowRoot && !roots.includes(root)) roots.push(root);
        }
        const copy = (rules, out) => {
            for (const rule of rules) {
                if (rule.selectorText !== undefined) {
                    if (rule.selectorText.includes(':hover')) {
                        out.push(`${rule.selectorText.replace(/:hover\\b/g, `[${mark}]`)} { ${rule.style.cssText} }`);
                    }
                } else if (rule.cssRules) {
                    const inner = [];
                    copy(rule.cssRules, inner);
                    if (inner.length) out.push(`${rule.cssText.slice(0, rule.cssText.indexOf('{'))} { ${inner.join('\\n')} }`);
                }
            }
        };
        for (const root of roots) {
            const out = [];
            for (const sheet of [...root.styleSheets, ...(root.adoptedStyleSheets || [])]) {
                try { copy(sheet.cssRules, out); } catch {}
            }
            if (!out.length) continue;
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(out.join('\\n'));
            root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
            state.sheets.push({ root: new WeakRef(root), sheet });
        }

        const chain = chainOf(element);
        for (const node of chain) node.setAttribute(mark, '');
        state.chain = chain.map((node) => new WeakRef(node));

        // The events of the pointer leaving what it was over and coming over this.
        const view = element.ownerDocument.defaultView;
        const send = (target, type, bubbles, Kind) => target.dispatchEvent(new Kind(type, {
            bubbles, cancelable: bubbles, composed: true, view, clientX: x, clientY: y,
            ...(Kind === PointerEvent ? { pointerId: 1, pointerType: 'mouse', isPrimary: true } : {}),
        }));
        const left = before.filter((node) => !chain.includes(node));
        if (before[0] && before[0] !== element) {
            send(before[0], 'pointerout', true, PointerEvent);
            send(before[0], 'mouseout', true, MouseEvent);
        }
        for (const node of left) { send(node, 'pointerleave', false, PointerEvent); send(node, 'mouseleave', false, MouseEvent); }
        send(element, 'pointerover', true, PointerEvent);
        send(element, 'mouseover', true, MouseEvent);
        for (const node of chain.filter((node) => !before.includes(node)).reverse()) {
            send(node, 'pointerenter', false, PointerEvent);
            send(node, 'mouseenter', false, MouseEvent);
        }
        send(element, 'pointermove', true, PointerEvent);
        send(element, 'mousemove', true, MouseEvent);
        return true;
        """

    /// Scrolls the page, or the box holding the element `ref` names (the
    /// nearest around it, itself included, that scrolls that way), by
    /// `amount` CSS px or most of what shows of it. Answers how far it went
    /// and what is left, and the elements with refs that came into view.
    static func scroll(_ ref: String?, _ direction: String, by amount: Double?, in agentTab: AgentTab) async throws -> String {
        // The refs to watch: those of the frame scrolled, from an outline
        // read now, so every element shown has one.
        let reading = try await read(agentTab)
        let prefix = ref.flatMap { $0.firstMatch(of: /^(f\d+)e/).map { String($0.output.1) } } ?? ""
        var lines: [String: String] = [:]
        var refs: [String] = []
        for line in reading.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.firstMatch(of: #/^- ((f\d+)?e\d+) /#), String(match.output.2 ?? "") == prefix else { continue }
            lines[String(match.output.1)] = trimmed
            refs.append(String(match.output.1))
        }
        var arguments: [String: Any] = ["direction": direction, "refs": refs, "amount": amount ?? 0]

        let answer: [String: Any]
        var what = "the page"
        if let ref {
            let element = try await element(ref, in: agentTab)
            answer = try await run(scrollScript, on: element, arguments: arguments) as? [String: Any] ?? [:]
            if answer["box"] as? String == "self" { what = describe(ref: ref, answer["what"]) }
            else if answer["box"] as? String == "holder" { what = "the box holding \(describe(ref: ref, answer["what"]))" }
        } else {
            guard let page = agentTab.tab.page else { throw AgentError(.failed, "Tab \(agentTab.ref) has no page to scroll.") }
            arguments.merge(["op": "run", "args": [String: Any](), "prefix": ""]) { $1 }
            answer = try await page.callAsyncJavaScript(
                AgentPageScript.source + "\nreturn await (async (element) => {\n\(scrollScript)\n})(null);",
                arguments: arguments, contentWorld: world
            ) as? [String: Any] ?? [:]
        }

        let moved = Int((answer["moved"] as? Double ?? 0).rounded())
        let left = Int((answer["left"] as? Double ?? 0).rounded())
        let end = ["down": "bottom", "up": "top", "right": "right end", "left": "left end"][direction] ?? "end"
        guard moved > 0 else { return "\(what) is at its \(end) already: nothing scrolled" }
        var line = "scrolled \(what) \(direction) \(moved) px"
        line += left > 0 ? " (\(left) px more that way)" : ", to its \(end)"
        let seen = (answer["seen"] as? [String] ?? []).compactMap { lines[$0] }
        guard !seen.isEmpty else { return line + "\nNothing more with a ref came into view." }
        return line + "\n" + untrusted((["now in view:"] + seen).joined(separator: "\n"), as: "page-changes")
    }

    /// Scrolls `element`'s box (or the page, without one) `direction` by
    /// `amount` (or, when 0, 80% of what shows), at once. Answers `{box, what, moved,
    /// left, seen}`: `box` "self", "holder" or "page" (the element's box
    /// being the page), how far it went, how far it could go on, and which
    /// of `refs` came into view that weren't in it before. In view means
    /// some of it shows within its frame and each box around it that clips.
    private static let scrollScript = """
        const doc = element ? element.ownerDocument : document;
        const across = direction === 'left' || direction === 'right';
        const sign = direction === 'up' || direction === 'left' ? -1 : 1;
        const up = (node) => node.parentElement || node.parentNode?.host || null;
        const scrolls = (node) => {
            const style = getComputedStyle(node);
            const overflow = across ? style.overflowX : style.overflowY;
            return /auto|scroll|overlay/.test(overflow)
                && (across ? node.scrollWidth > node.clientWidth : node.scrollHeight > node.clientHeight);
        };
        let box = null;
        for (let node = element; node && node !== doc.body && node !== doc.documentElement; node = up(node)) {
            if (node instanceof Element && scrolls(node)) { box = node; break; }
        }
        const scroller = box || doc.scrollingElement || doc.documentElement;
        const view = doc.defaultView;
        const shownSize = box ? (across ? box.clientWidth : box.clientHeight) : (across ? view.innerWidth : view.innerHeight);
        const step = amount || Math.round(shownSize * 0.8);

        /// Whether a box clips what is in it, by element: the same before
        /// and after scrolling, so asked once.
        const clips = new Map();
        const seen = (node) => {
            let rect = node.getBoundingClientRect();
            if (!rect.width && !rect.height) return false;
            let [left, top, right, bottom] = [rect.left, rect.top, rect.right, rect.bottom];
            const clip = (l, t, r, b) => { left = Math.max(left, l); top = Math.max(top, t); right = Math.min(right, r); bottom = Math.min(bottom, b); };
            let at = node;
            for (;;) {
                const own = at.ownerDocument;
                for (let around = up(at); around && around !== own.body && around !== own.documentElement; around = up(around)) {
                    if (!(around instanceof Element)) continue;
                    if (!clips.has(around)) {
                        const style = own.defaultView.getComputedStyle(around);
                        clips.set(around, style.overflowX !== 'visible' || style.overflowY !== 'visible');
                    }
                    if (!clips.get(around)) continue;
                    const box = around.getBoundingClientRect();
                    clip(box.left, box.top, box.right, box.bottom);
                }
                const frameView = own.defaultView;
                clip(0, 0, frameView.innerWidth, frameView.innerHeight);
                if (frameView === window || !frameView.frameElement) break;
                const holder = frameView.frameElement.getBoundingClientRect();
                const dx = holder.left + frameView.frameElement.clientLeft, dy = holder.top + frameView.frameElement.clientTop;
                left += dx; right += dx; top += dy; bottom += dy;
                at = frameView.frameElement;
            }
            return right > left && bottom > top;
        };
        const inView = () => new Set(refs.filter((ref) => { const node = nerdaAgent.element(ref); return node && seen(node); }));

        const before = inView();
        const start = across ? scroller.scrollLeft : scroller.scrollTop;
        scroller.scrollBy({ [across ? 'left' : 'top']: sign * step, behavior: 'instant' });
        const now = across ? scroller.scrollLeft : scroller.scrollTop;
        const most = across ? scroller.scrollWidth - scroller.clientWidth : scroller.scrollHeight - scroller.clientHeight;
        const after = inView();
        return {
            box: !box ? 'page' : box === element ? 'self' : 'holder',
            what: element ? nerdaAgent.describe(element) : null,
            moved: Math.abs(now - start),
            left: Math.max(0, sign > 0 ? most - now : now),
            seen: refs.filter((ref) => after.has(ref) && !before.has(ref)),
        };
        """
}
