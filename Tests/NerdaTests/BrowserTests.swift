import Foundation
import Testing
@testable import Nerda

private let somewhere = URL(string: "https://example.com")!

@MainActor
@Test func closingTabsHandsTheScreenOn() {
    let browser = Browser()
    browser.open(somewhere)
    browser.open(somewhere)
    browser.open(somewhere)
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
    browser.open(somewhere)
    browser.open(somewhere)
    let (top, bottom) = (browser.tabs[0].id, browser.tabs[1].id)
    browser.selectedID = bottom
    browser.close(bottom)
    #expect(browser.selectedID == top)
}

@MainActor
@Test func openingATabPutsItFirstAndShowsIt() {
    let browser = Browser()
    #expect(browser.tabs.isEmpty)
    browser.open(URL(string: "https://www.google.com/")!)
    #expect(browser.tabs.first?.title == "google.com")
    #expect(browser.selectedID == browser.tabs.first?.id)
}

@Test(arguments: [
    ("google.com", "https://google.com"),
    ("  github.com/apple/swift ", "https://github.com/apple/swift"),
    ("http://example.com", "http://example.com"),
    ("localhost:3000", "http://localhost:3000"),
    ("192.168.1.1", "https://192.168.1.1"),
    ("ob-havo toshkent", "https://www.google.com/search?q=ob-havo%20toshkent"),
    ("swift", "https://www.google.com/search?q=swift"),
])
func typedTextBecomesAnAddress(input: String, expected: String) {
    #expect(Address.url(from: input)?.absoluteString == expected)
}

@Test func nothingTypedGoesNowhere() {
    #expect(Address.url(from: "   ") == nil)
}
