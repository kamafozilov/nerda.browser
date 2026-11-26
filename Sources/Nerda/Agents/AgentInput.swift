import AppKit
import WebKit

/// Real input an agent sends a page: events made as the Mac's own and given
/// straight to the page's view, so the page sees trusted events, though its
/// window is off screen and never key.
///
/// Every event made here is marked (`isAgents`): an Agent tab's page view
/// gets them by the same path as the owner's clicks and keys once the owner
/// watches it, and Take over (#145) must tell the two apart.
@MainActor
enum AgentInput {
    /// The events sent by agents, held weakly: once the page is done with
    /// one it goes, and so does its mark.
    private static let sent = NSHashTable<NSEvent>.weakObjects()

    /// Whether an agent sent `event` (it came through here), rather than the
    /// owner's mouse or keyboard.
    static func isAgents(_ event: NSEvent) -> Bool { sent.contains(event) }

    /// A person's click at `point` of the page, in points from the top left
    /// of its view: the pointer moved there, pressed and let go.
    static func click(_ page: WKWebView, at point: CGPoint) throws {
        try send(.mouseMoved, to: page, at: point)
        try send(.leftMouseDown, to: page, at: point)
        try send(.leftMouseUp, to: page, at: point)
    }

    /// The pointer moved to `point` of the page, its button up.
    static func move(_ page: WKWebView, to point: CGPoint) throws {
        try send(.mouseMoved, to: page, at: point)
    }

    /// A person's drag from `start` to `end` of the page: the pointer
    /// pressed at `start`, moved there in `steps` moves a frame apart
    /// (the first a few points out, past where a press becomes a drag),
    /// and let go at `end`. Once `stopping` says so (the page is held by a
    /// dialog), no more moves are sent: it is let go of where it is.
    static func drag(_ page: WKWebView, from start: CGPoint, to end: CGPoint, steps: Int = 12,
                     stopping: () -> Bool = { false }) async throws {
        try send(.mouseMoved, to: page, at: start)
        try send(.leftMouseDown, to: page, at: start)
        let length = max(hypot(end.x - start.x, end.y - start.y), 1)
        let nudge = CGPoint(x: start.x + 6 * (end.x - start.x) / length, y: start.y + 6 * (end.y - start.y) / length)
        var points = [nudge]
        for step in 1...steps {
            let part = CGFloat(step) / CGFloat(steps)
            points.append(CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part))
        }
        points.append(end)
        var at = start
        for point in points {
            try await Task.sleep(for: .milliseconds(16))
            if stopping() { break }
            try send(.leftMouseDragged, to: page, at: point)
            at = point
        }
        try await Task.sleep(for: .milliseconds(16))
        try send(.leftMouseUp, to: page, at: at)
    }

    /// One mouse event of `type` at `point` of the page (points from the top
    /// left of its view), made as the Mac's own, marked, and given to the
    /// page's view.
    private static func send(_ type: NSEvent.EventType, to page: WKWebView, at point: CGPoint) throws {
        guard let window = page.window else {
            throw AgentError(.failed, "The page isn't in its window, so the pointer can't reach it. Try again.")
        }
        let inView = page.isFlipped ? point : CGPoint(x: point.x, y: page.bounds.height - point.y)
        let location = page.convert(inView, to: nil)
        let pressed = type == .leftMouseDown || type == .leftMouseDragged
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1, pressure: pressed ? 1 : 0
        ) else { return }
        sent.add(event)
        switch type {
        case .mouseMoved: page.mouseMoved(with: event)
        case .leftMouseDown: page.mouseDown(with: event)
        case .leftMouseDragged: page.mouseDragged(with: event)
        default: page.mouseUp(with: event)
        }
    }
}

/// Keys an agent presses: the keyboard's own events, given straight to the
/// page's view. A ⌘ chord goes as a key equivalent, as AppKit sends one, so
/// the page has its say before any menu would.
///
/// A key the page leaves alone WebKit hands back to the app (`NSApp
/// sendEvent`), where it would go to the owner's key window: ⌘W would close
/// the owner's tab, a letter would land in their address bar. So agents'
/// keys are caught there (`listen()`) and go no further, but for the few
/// editing chords a page leaves to the browser (⌘A), done on the page.
extension AgentInput {
    /// A key as agents name it: "Enter", "a", "Meta+a", "Shift+Tab".
    struct Key: Equatable {
        let code: UInt16
        let characters: String
        let modifiers: NSEvent.ModifierFlags
        /// How the answer names it: "⌘A", "⇧Tab", "Enter".
        let name: String

        init(_ text: String) throws {
            var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            // "Meta++" and "+": the key is the plus sign itself.
            if text.hasSuffix("+") { parts = Array(parts.dropLast(2)) + ["+"] }
            guard let last = parts.last, !last.isEmpty else {
                throw AgentError(.invalid, "Give key as a key's name, such as Enter, a, Meta+a or Shift+Tab.")
            }
            var modifiers: NSEvent.ModifierFlags = []
            for part in parts.dropLast() {
                guard let modifier = Self.modifiers[part.lowercased()] else {
                    throw AgentError(.invalid, "\(part) is not a modifier key: use Meta (⌘), Control, Alt (⌥) or Shift.")
                }
                modifiers.insert(modifier)
            }
            var characters: String
            let keyName: String
            if let named = Self.named[last.lowercased().replacingOccurrences(of: " ", with: "")] {
                code = named.code
                characters = named.characters
                keyName = named.name
            } else if last.count == 1, let typed = Self.typed(Character(last)) {
                code = typed.code
                characters = last
                if typed.shifted { modifiers.insert(.shift) }
                keyName = last.uppercased()
            } else {
                throw AgentError(.invalid, """
                    \(last) is not a key Nerda knows. Use a character, or Enter, Tab, Space, Backspace, Delete, \
                    Escape, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown or F1 to F12.
                    """)
            }
            if modifiers.contains(.shift), characters.count == 1, characters.unicodeScalars.first!.value < 0xF700 {
                characters = characters.uppercased()
            }
            self.characters = characters
            self.modifiers = modifiers
            let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            let shown = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
            name = shown + keyName
        }

        private static let modifiers: [String: NSEvent.ModifierFlags] = [
            "meta": .command, "cmd": .command, "command": .command, "⌘": .command,
            "control": .control, "ctrl": .control, "⌃": .control,
            "alt": .option, "option": .option, "opt": .option, "⌥": .option,
            "shift": .shift, "⇧": .shift,
        ]

        private static let named: [String: (code: UInt16, characters: String, name: String)] = {
            var keys: [String: (UInt16, String, String)] = [
                "enter": (36, "\r", "Enter"), "return": (36, "\r", "Enter"),
                "tab": (48, "\t", "Tab"), "space": (49, " ", "Space"),
                "backspace": (51, "\u{7F}", "Backspace"),
                "delete": (117, String(UnicodeScalar(NSDeleteFunctionKey)!), "Delete"),
                "escape": (53, "\u{1B}", "Escape"), "esc": (53, "\u{1B}", "Escape"),
                "arrowup": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!), "ArrowUp"),
                "arrowdown": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!), "ArrowDown"),
                "arrowleft": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), "ArrowLeft"),
                "arrowright": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!), "ArrowRight"),
                "home": (115, String(UnicodeScalar(NSHomeFunctionKey)!), "Home"),
                "end": (119, String(UnicodeScalar(NSEndFunctionKey)!), "End"),
                "pageup": (116, String(UnicodeScalar(NSPageUpFunctionKey)!), "PageUp"),
                "pagedown": (121, String(UnicodeScalar(NSPageDownFunctionKey)!), "PageDown"),
            ]
            for direction in ["up", "down", "left", "right"] { keys[direction] = keys["arrow" + direction] }
            let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            for (index, code) in functionCodes.enumerated() {
                keys["f\(index + 1)"] = (code, String(UnicodeScalar(NSF1FunctionKey + index)!), "F\(index + 1)")
            }
            return keys.mapValues { (code: $0.0, characters: $0.1, name: $0.2) }
        }()

        /// The key that types `character` on a US keyboard, and whether
        /// Shift is held for it; for a character none types, no key the
        /// page knows (its `code` is "Unidentified"), as for a character an
        /// input method typed.
        private static func typed(_ character: Character) -> (code: UInt16, shifted: Bool)? {
            let lower = Character(character.lowercased())
            if let code = codes[lower] { return (code, character != lower) }
            if let base = shifted[character], let code = codes[base] { return (code, true) }
            return (0xFFFF, false)
        }

        /// The symbols Shift types on a US keyboard, by the key's own.
        private static let shifted = Dictionary(uniqueKeysWithValues: zip(
            Array("!@#$%^&*()_+{}|:\"<>?~"), Array("1234567890-=[]\\;',./`")
        ))

        private static let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, " ": 49, "`": 50,
        ]
    }

    /// Presses `key` on the page: down and up, as the keyboard sends them.
    static func press(_ key: Key, on page: WKWebView) throws {
        guard let window = page.window else {
            throw AgentError(.failed, "The page isn't in its window, so it can't take keys. Try again.")
        }
        listen()
        let events = [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.modifiers.contains(.shift) ? key.characters : key.characters.lowercased(),
                isARepeat: false, keyCode: key.code
            )
        }
        guard events.count == 2 else { throw AgentError(.failed, "Nerda couldn't make the key \(key.name).") }
        for event in events {
            sent.add(event)
            pages.setObject(page, forKey: event)
        }
        let (down, up) = (events[0], events[1])
        // A key equivalent goes to the first responder only. In the Agent
        // window, never key, the page can be that without taking anyone's
        // keyboard; in the owner's window (a watched tab) it goes as a key.
        if key.modifiers.contains(.command), window is AgentWindow {
            if window.firstResponder !== page { window.makeFirstResponder(page) }
            if !page.performKeyEquivalent(with: down) { page.keyDown(with: down) }
        } else {
            page.keyDown(with: down)
        }
        page.keyUp(with: up)
    }

    /// The page each key an agent pressed went to, for one handed back.
    private static let pages = NSMapTable<NSEvent, WKWebView>.weakToWeakObjects()
    private static var listening = false

    /// Catches agents' keys handed back to the app (see above).
    private static func listen() {
        guard !listening else { return }
        listening = true
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let agents = MainActor.assumeIsolated {
                guard isAgents(event) else { return false }
                if event.type == .keyDown, let page = pages.object(forKey: event),
                   let action = editing[event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue]?[event.keyCode] {
                    NSApp.sendAction(action, to: page, from: nil)
                }
                return true
            }
            return agents ? nil : event
        }
    }

    /// Editing chords a page leaves to the browser's menu, done on the page
    /// itself. Not copy, cut or paste: the clipboard is the owner's.
    private static let editing: [UInt: [UInt16: Selector]] = [
        NSEvent.ModifierFlags.command.rawValue: [0: #selector(NSText.selectAll(_:))],
    ]
}
