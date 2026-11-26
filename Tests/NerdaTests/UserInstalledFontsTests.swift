import Foundation
import Testing
import WebKit
@testable import Nerda

/// The tests run their pages without the fonts installed on the Mac beyond
/// its own (NERDA_USER_INSTALLED_FONTS=0, set in TestRun.c): with them, each
/// page started in a process already running has the main thread wait on
/// the Mac's sandbox to approve two file extensions for its fonts, and under
/// a run's load one such wait now and then lasts 5 s.
@MainActor
struct UserInstalledFontsTests {
    private func allowsUserFonts(_ page: WKWebView) -> Bool? {
        page.configuration.preferences.value(forKey: "_shouldAllowUserInstalledFonts") as? Bool
    }

    /// A tab's page, in the run's own data store or in one of a test's.
    @Test func aTabsPageLeavesTheMacsInstalledFontsOut() throws {
        #expect(!UserInstalledFonts.allowed)
        for store in [WKWebsiteDataStore.nonPersistent(), .nonPersistent()] {
            let browser = Browser(dataStore: store)
            let tab = browser.open(URL(string: "about:blank")!, inBackground: true)
            let page = try #require(tab.page)
            #expect(allowsUserFonts(page) == false)
            browser.closeAll()
        }
    }

    /// A spare page, made ahead of the tab that takes it.
    @Test func aSparePageLeavesTheMacsInstalledFontsOut() {
        #expect(allowsUserFonts(Tab.sparePage(for: .nonPersistent())) == false)
    }

    /// Reader's page, in the shared process pool too.
    @Test func readersPageLeavesTheMacsInstalledFontsOut() {
        let tab = Tab(waitingFor: URL(string: "about:blank")!)
        #expect(allowsUserFonts(Reader.page(for: tab)) == false)
    }
}
