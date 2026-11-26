import WebKit
@testable import Nerda

/// A page configuration of a test's own, as WebKit makes one, but leaving
/// the Mac's installed fonts out as the run's tabs do (`UserInstalledFonts`):
/// a page given one can still take a process already running, a swap to
/// another site's for one, and wait on the Mac's sandbox for its fonts.
/// Every test that makes its own configuration starts from this one.
@MainActor
func testConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    Tab.leaveUserInstalledFontsOutIfAsked(configuration.preferences)
    return configuration
}
