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
    /// and let go at `end`.
    static func drag(_ page: WKWebView, from start: CGPoint, to end: CGPoint, steps: Int = 12) async throws {
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
        for point in points {
            try await Task.sleep(for: .milliseconds(16))
            try send(.leftMouseDragged, to: page, at: point)
        }
        try await Task.sleep(for: .milliseconds(16))
        try send(.leftMouseUp, to: page, at: end)
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
