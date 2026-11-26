import AppKit

/// Runs `body` as with Keyboard navigation on (System Settings › Keyboard),
/// whatever the Mac's setting: every control a key view, so Tab goes through
/// buttons as well as text fields. AppKit reads the setting from the Mac's
/// global preferences and keeps it, so a test can't set it for itself; this
/// answers AppKit's own question for every window, yes, while `body` runs.
/// `body` isn't async: nothing else runs on the main thread meanwhile, so no
/// other test sees the setting changed.
@MainActor
func withKeyboardNavigation<T>(_ body: () throws -> T) rethrows -> T {
    let selector = NSSelectorFromString("_allowsAnyValidResponder")
    guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
        preconditionFailure("AppKit no longer asks windows \(selector)")
    }
    let on: @convention(block) (NSWindow) -> Bool = { _ in true }
    let before = method_setImplementation(method, imp_implementationWithBlock(on))
    defer { method_setImplementation(method, before) }
    return try body()
}
