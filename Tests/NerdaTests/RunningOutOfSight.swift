import WebKit
@testable import Nerda

/// A browser with a data store of its own, Low Power Mode off for it
/// whatever the Mac's: its pages out of sight run (`Tab.hiddenPolicy`).
/// In the mode they would be suspended, and a test waiting on a hidden
/// page's timer or event would pass or fail by the Mac's setting.
@MainActor
func browserRunningOutOfSight() -> Browser {
    let browser = Browser(dataStore: .nonPersistent())
    LowPowerMode.force(false, for: browser.dataStore)
    return browser
}
