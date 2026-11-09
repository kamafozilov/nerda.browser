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

/// What came from the server counts as on its way while it is written, as
/// kept once on disk, and reads back as it came, the disk off the main thread.
@MainActor @Test func mediaKeptIsReadBackAfterItIsWritten() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "Nerda media test \(UUID().uuidString)")
    let url = try #require(URL(string: "https://example.com/v.mp4"))
    let stored = try #require(MediaCache.Stored(url: url, path: path))
    defer { stored.remove() }
    let first = Data((0..<100).map { UInt8($0) }), second = Data((100..<200).map { UInt8($0) })
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        stored.keep(first, at: 0) {}
        stored.keep(second, at: 100) { done.resume() }
        #expect(stored.kept(at: 0) == nil)
        #expect(stored.coming(at: 150))
        #expect(stored.covered(from: 0) == 200)
    }
    #expect(stored.writing.isEmpty)
    #expect(stored.have == [0..<200])
    let read = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
        stored.read(50..<150) { done.resume(returning: $0) }
    }
    #expect(read == Data((50..<150).map { UInt8($0) }))
}
