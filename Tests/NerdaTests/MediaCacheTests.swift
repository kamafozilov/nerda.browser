import Foundation
import Testing
@testable import Nerda

/// The address WebKit is given leads back to the page's own, query and all.
@Test func mediaAddressLeadsBackToThePagesOwn() throws {
    let handed = try #require(URL(string: "nerda-media://36.fayllar.com/a%20b.mp4?token=x&expires=1#t=10"))
    #expect(MediaCache.original(handed).absoluteString == "https://36.fayllar.com/a%20b.mp4?token=x&expires=1#t=10")
    let plain = try #require(URL(string: "https://example.com/v.mp4"))
    #expect(MediaCache.original(plain) == plain)
}

/// The ranges WebKit asks for, and the servers' answers, read as they are meant.
@Test func mediaRangesAreReadAsAskedAndAnswered() {
    #expect(MediaCache.range("bytes=0-1")! == (0, 1))
    #expect(MediaCache.range("bytes=500-")! == (500, nil))
    #expect(MediaCache.range("bytes=9-3") == nil)
    #expect(MediaCache.range("items=0-1") == nil)
    #expect(MediaCache.range(nil) == nil)
    #expect(MediaCache.contentRange("bytes 100-199/1612946996")! == (100, 1_612_946_996))
    #expect(MediaCache.contentRange("bytes */1000") == nil)
    #expect(MediaCache.contentRange("bytes 0-1/*") == nil)
}
