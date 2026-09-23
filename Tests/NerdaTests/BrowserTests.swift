import Testing
@testable import Nerda

@MainActor
@Test func closingTabsHandsTheScreenOn() {
    let browser = Browser()
    browser.newTab()
    browser.newTab()
    let (top, middle, bottom) = (browser.tabs[0].id, browser.tabs[1].id, browser.tabs[2].id)

    // A tab that isn't showing goes without moving the selection.
    browser.selectedID = middle
    browser.close(top)
    #expect(browser.selectedID == middle)

    // The one showing hands over to the one sliding into its place…
    browser.close(middle)
    #expect(browser.selectedID == bottom)

    // …and the last one leaves nothing selected.
    browser.close(bottom)
    #expect(browser.tabs.isEmpty)
    #expect(browser.selectedID == nil)
}

@MainActor
@Test func closingTheBottomTabSelectsTheOneAbove() {
    let browser = Browser()
    browser.newTab()
    let (top, bottom) = (browser.tabs[0].id, browser.tabs[1].id)
    browser.selectedID = bottom
    browser.close(bottom)
    #expect(browser.selectedID == top)
}
