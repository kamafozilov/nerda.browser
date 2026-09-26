import AppKit
import Foundation
import Testing
@testable import Nerda

private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A PNG `side` pixels square, red.
private func png(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

private func pixels(_ image: NSImage?) -> [Int] {
    (image?.representations ?? []).map(\.pixelsWide).sorted()
}

/// A big icon is kept as big as it is shown, 16 points, with a version for
/// 1× and 2× screens, in memory and on disk; one kept big by an earlier
/// version is written back small the next time it is read. A small one is
/// kept as it came.
@MainActor
@Test func bigIconsAreKeptAsBigAsTheyAreShown() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let big = root.appending(path: "big.png")
    try png(1024).write(to: big)
    let site = "https://big.invalid"

    let icons = Favicons()
    icons.folder = root.appending(path: "Favicons")
    await icons.load(site, icon: big)
    let image = icons.icon(site).image
    #expect(pixels(image) == [16, 32])
    #expect(image?.size == NSSize(width: 16, height: 16))
    #expect(icons.icon(site).tint?.colors.count == 1)
    let kept = try #require(FileManager.default.contentsOfDirectory(at: icons.folder!, includingPropertiesForKeys: nil).first)
    #expect(pixels(NSImage(data: try Data(contentsOf: kept))) == [16, 32])

    // As an earlier version left it: the icon as it came.
    try png(1024).write(to: kept)
    let next = Favicons()
    next.folder = icons.folder
    await next.load(site)
    #expect(pixels(next.icon(site).image) == [16, 32])
    #expect(try Data(contentsOf: kept).count < 20_000)

    #expect(Favicons.shrunk(NSImage(data: png(32))!) == nil)
}

/// A site that answers without an icon isn't asked again for a week, even
/// across launches; one that couldn't be reached is, the next time.
@MainActor
@Test func sitesWithoutAnIconAreAskedAgainAfterAWeek() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appending(path: "server")
    try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
    try Data("Not found".utf8).write(to: server.appending(path: "favicon.ico"))
    let site = server.absoluteString.trimmingCharacters(in: ["/"])

    func launch() async -> Favicons {
        let icons = Favicons()
        icons.folder = root.appending(path: "Favicons")
        await icons.load(site)
        return icons
    }
    #expect(await launch().icon(site).failed)

    // It has one now, but isn't asked yet.
    try png(16).write(to: server.appending(path: "favicon.ico"))
    let asked = await launch().icon(site)
    #expect(asked.failed && asked.image == nil)

    let marker = try #require(FileManager.default.contentsOfDirectory(at: root.appending(path: "Favicons"),
                                                                       includingPropertiesForKeys: nil).first)
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-Favicons.retryAfter - 60)],
                                          ofItemAtPath: marker.path(percentEncoded: false))
    #expect(await launch().icon(site).image != nil)

    // Unreachable: nothing is kept on disk, so it is asked again.
    let offline = "http://127.0.0.1:9"
    let icons = await launch()
    await icons.load(offline)
    #expect(icons.icon(offline).failed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Favicons").path(percentEncoded: false)).count == 1)
}

/// An icon arriving redraws only what shows that site's icon.
@MainActor
@Test func iconsAreWatchedOneSiteAtATime() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "icon.png")
    try png(16).write(to: file)

    final class Flag: @unchecked Sendable { var raised = false }
    let icons = Favicons()
    let watched = Flag()
    withObservationTracking {
        let icon = icons.icon("https://a.invalid")
        _ = (icon.image, icon.tint, icon.failed)
    } onChange: { watched.raised = true }

    await icons.load("https://b.invalid", icon: file)
    #expect(!watched.raised)
    await icons.load("https://a.invalid", icon: file)
    #expect(watched.raised)
}

/// Icons no view shows are let go past the last `goneLimit` of them, and
/// read again when shown again; one on screen stays however many go.
@MainActor
@Test func iconsNoViewShowsAreLetGo() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "icon.png")
    try png(16).write(to: file)
    let icons = Favicons()
    icons.folder = root.appending(path: "Favicons")
    let (gone, onScreen) = ("https://gone.invalid", "https://shown.invalid")
    await icons.load(gone, icon: file)
    await icons.load(onScreen, icon: file)

    icons.show(onScreen)
    icons.show(gone)
    icons.hide(gone)
    for i in 0..<Favicons.goneLimit {
        icons.show("https://\(i).invalid")
        icons.hide("https://\(i).invalid")
    }
    #expect(icons.icon(gone).image == nil)
    #expect(icons.icon(onScreen).image != nil)

    await icons.load(gone)
    #expect(icons.icon(gone).image != nil)
}

/// Deleting history takes the icons of the sites it named off disk.
@MainActor
@Test func forgottenSitesLeaveNoIconOnDisk() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "icon.png")
    try png(16).write(to: file)
    let icons = Favicons()
    icons.folder = root.appending(path: "Nerda Dev/Favicons")
    await icons.load("https://kept.invalid", icon: file)
    await icons.load("https://visited.invalid", icon: file)

    icons.forget(keeping: ["https://kept.invalid"])
    let names = try FileManager.default.contentsOfDirectory(atPath: icons.folder!.path(percentEncoded: false))
    #expect(names.map { $0.removingPercentEncoding } == ["https://kept.invalid"])
}
