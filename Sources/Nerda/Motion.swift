import AppKit
import SwiftUI

/// System Settings › Accessibility › Display › Reduce Motion, in one place.
/// With it on, nothing slides, scales or bounces: what moved into place is
/// there at once, and what grew in fades in instead. Fades that only show a
/// state (hover, a spinner coming in) stay, as the Mac's own do.
///
/// Read here rather than from SwiftUI's environment because much of what
/// moves is started outside any view, by `Browser` opening and closing tabs.
enum Motion {
    /// Kept up to date as the setting changes, rather than asked of
    /// `NSWorkspace` on every tab opened.
    private(set) static var reduced: Bool = {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Motion.reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }()

    /// What takes the place of movement where something still has to come
    /// and go: short enough not to hold anyone up.
    static let fade = Animation.easeOut(duration: 0.15)

    /// For an animation that moves things (rows making way, a card sliding
    /// up, a scroll): none with Reduce Motion, so they are in place at once.
    static func moving(_ animation: Animation, reduced: Bool = reduced) -> Animation? {
        reduced ? nil : animation
    }

    /// For an animation that brings something in that also grows or springs
    /// (a menu, a strip): a plain fade with Reduce Motion.
    static func fading(_ animation: Animation, reduced: Bool = reduced) -> Animation {
        reduced ? fade : animation
    }

    /// For a transition that moves or scales a view in and out: a
    /// cross-fade with Reduce Motion.
    static func moving(_ transition: AnyTransition, reduced: Bool = reduced) -> AnyTransition {
        reduced ? .opacity : transition
    }
}
