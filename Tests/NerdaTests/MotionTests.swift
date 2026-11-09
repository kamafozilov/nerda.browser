import AppKit
import SwiftUI
import Testing
@testable import Nerda

/// With Reduce Motion, what moves things is dropped, and what brings
/// something in with a spring or a scale becomes a short fade.
@MainActor
@Test func reduceMotionDropsMovementAndFadesInstead() {
    let snappy = Animation.snappy(duration: 0.2)
    #expect(Motion.moving(snappy, reduced: false) == snappy)
    #expect(Motion.moving(snappy, reduced: true) == nil)

    let spring = Animation.spring(duration: 0.3, bounce: 0.12)
    #expect(Motion.fading(spring, reduced: false) == spring)
    #expect(Motion.fading(spring, reduced: true) == Motion.fade)
}

/// The setting is the Mac's, read again as it changes, and the tabs'
/// slide follows it.
@MainActor
@Test func reduceMotionFollowsTheSystemSetting() {
    let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #expect(Motion.reduced == system)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                               object: NSWorkspace.shared)
    #expect(Motion.reduced == system)
    #expect(Animation.slide == (system ? nil : .smooth(duration: 0.25)))
}
