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
        guard let window = page.window else {
            throw AgentError(.failed, "The page isn't in its window, so it can't be clicked. Try again.")
        }
        let inView = page.isFlipped ? point : CGPoint(x: point.x, y: page.bounds.height - point.y)
        let location = page.convert(inView, to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            sent.add(event)
            switch type {
            case .mouseMoved: page.mouseMoved(with: event)
            case .leftMouseDown: page.mouseDown(with: event)
            default: page.mouseUp(with: event)
            }
        }
    }
}
