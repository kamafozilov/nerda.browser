import Foundation
import Testing
@testable import Nerda

/// Your own search engine takes only a web address with a %s in it, and what
/// is typed fills the %s without changing the address around it.
@Test func customSearchAddressIsAWebAddressWithAPlaceForTheSearch() {
    #expect(SearchEngine.validAddress("  https://kagi.com/search?q=%s ") == "https://kagi.com/search?q=%s")
    #expect(SearchEngine.validAddress("http://localhost:8080/?q=%s") == "http://localhost:8080/?q=%s")
    #expect(SearchEngine.validAddress("https://kagi.com/search?q=") == nil)
    #expect(SearchEngine.validAddress("javascript:alert(%s)") == nil)
    #expect(SearchEngine.validAddress("file:///etc/%s") == nil)
    #expect(SearchEngine.validAddress("kagi.com/search?q=%s") == nil)
    #expect(SearchEngine.validAddress("https://%s.example.com/") == nil)

    let url = SearchEngine.fill("https://example.com/search?q=%s&lang=en", with: "a&b=c #d/é")
    #expect(url?.absoluteString == "https://example.com/search?q=a%26b%3Dc%20%23d%2F%C3%A9&lang=en")
    #expect(url?.host() == "example.com")
}

/// Each engine searches where it should, and those without suggestions ask for none.
@Test func searchEnginesSearchAndSuggest() {
    #expect(SearchEngine.startpage.search("swift ui")?.absoluteString == "https://www.startpage.com/sp/search?query=swift%20ui")
    #expect(SearchEngine.kagi.search("swift")?.absoluteString == "https://kagi.com/search?q=swift")
    #expect(SearchEngine.ecosia.guesses("swift")?.absoluteString == "https://ac.ecosia.org/autocomplete?q=swift&type=list")
    #expect(SearchEngine.kagi.suggests && !SearchEngine.perplexity.suggests && !SearchEngine.custom.suggests)
}
