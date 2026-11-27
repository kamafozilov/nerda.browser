import AppKit
import Testing
import WebKit

/// The app's accessibility, as VoiceOver turns it on (`AXEnhancedUserInterface`
/// on the app), kept from WebKit's pages. WebKit hears of it as AppKit posts
/// the change, and from then on reaches into the process of each page made,
/// and of each page open then, whenever a page is made in it: a process
/// WebKit has just suspended is woken (#202's tests, `HiddenPagesTests`).
/// It never turns that off again by itself.
@MainActor
enum WebKitAccessibility {
    /// Tests whose pages must never hear of accessibility, running now.
    private static var apart = 0
    /// Whether a test has the app's accessibility on now.
    private static var on = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` with the app's accessibility on, as VoiceOver has it, once
    /// no test is running that keeps its pages apart from it. WebKit is told
    /// it went off again at once, in the same turn of the main thread, so
    /// no page is made meanwhile, and its own accessibility is reset (SPI
    /// for WebKit's own tests).
    static func turnedOn(_ body: () async throws -> Void) async rethrows {
        while on || apart > 0 { await wait() }
        on = true
        defer {
            NSApp.accessibilitySetValue(false, forAttribute: attribute)
            on = false
            wakeAll()
        }
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        NotificationCenter.default.post(name: changed, object: NSApp, userInfo: [attribute.rawValue: false])
        let reset = NSSelectorFromString("_resetAccessibilityModeForTesting")
        let type: AnyObject = WKWebView.self
        if type.responds(to: reset) { _ = type.perform(reset) }
        try await body()
    }

    /// Runs `body` while no test has the app's accessibility on, and none
    /// turns it on until it is done.
    static func keptApart(_ body: () async throws -> Void) async rethrows {
        while on { await wait() }
        apart += 1
        defer {
            apart -= 1
            wakeAll()
        }
        try await body()
    }

    /// Whether WebKit's accessibility is on for the test run (SPI for
    /// WebKit's own tests), as a page asked anything by accessibility turns it.
    static func webKitsIsOn() throws -> Bool {
        let selector = NSSelectorFromString("_isAccessibilityEnabledForTesting")
        let type: AnyClass = WKWebView.self
        let method = try #require(class_getClassMethod(type, selector), "WebKit no longer says whether its accessibility is on")
        typealias Getter = @convention(c) (AnyClass, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(type, selector)
    }

    private static let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private static let changed = Notification.Name("NSApplicationDidChangeAccessibilityEnhancedUserInterfaceNotification")

    private static func wait() async {
        await withCheckedContinuation { waiting.append($0) }
    }

    private static func wakeAll() {
        let woken = waiting
        waiting = []
        for continuation in woken { continuation.resume() }
    }
}

/// A suite whose pages never hear of the app's accessibility: no test turns
/// it on while the suite runs (`WebKitAccessibility`).
nonisolated struct ApartFromAccessibility: SuiteTrait, TestScoping {
    @concurrent func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void) async throws {
        try await WebKitAccessibility.keptApart { try await function() }
    }
}

extension Trait where Self == ApartFromAccessibility {
    static var apartFromAccessibility: Self { Self() }
}
