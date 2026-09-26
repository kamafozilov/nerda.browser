import AppKit
import os
import SwiftUI

/// Site icons, fetched once and kept, so a row that appears again draws its
/// icon in its first frame instead of waiting on the network. Kept on disk
/// too: a tab from the last run sleeps until shown, and the icon its page
/// names (all some sites have: their /favicon.ico is empty) is only found
/// in the page.
final class Favicons {
    static let shared = Favicons()
    static let folder = Edition.folder.appending(path: "Favicons")

    /// Where icons are kept between runs; nil keeps them to this run, as in tests.
    // ponytail: an icon once kept is never fetched again; refresh it on page
    // load if sites changing their icons turns out to matter.
    var folder: URL?

    /// One site's icon, observed on its own: an icon arriving redraws the
    /// views showing that site, not every icon in every window.
    @Observable
    final class Icon {
        fileprivate(set) var image: NSImage?
        /// Its colours, for its site's pinned tile.
        fileprivate(set) var tint: Tint?
        fileprivate(set) var failed = false
    }

    private var icons: [String: Icon] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// How many views show each site's icon right now.
    private var shown: [String: Int] = [:]
    /// Sites no view shows any more, the longest gone first.
    private var gone: [String] = []
    /// How many icons no view shows are kept, to come back at once (the
    /// history page scrolled back up): a few screens of it, a megabyte or so.
    static let goneLimit = 200
    /// The icons `preload` is reading, until the first view asks for one.
    private var preloading: (reads: DispatchGroup, read: OSAllocatedUnfairLock<[String: Found]>)?

    /// The key an icon is kept under: scheme, host and port, so a local server
    /// (http://localhost:3000) is asked, not https://localhost. nil for
    /// addresses that have no site (file:, about:).
    nonisolated static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// The site's icon, as far as it has come; one to watch while it comes.
    func icon(_ site: String) -> Icon {
        finishPreload()
        if let icon = icons[site] { return icon }
        let icon = Icon()
        icons[site] = icon
        return icon
    }

    /// The icons kept on disk for these sites, read at launch, side by side
    /// off the main thread, while the window is made: the tabs come back with
    /// their icons in their first frame.
    func preload(_ sites: [URL]) {
        guard let folder else { return }
        let reads = DispatchGroup(), read = OSAllocatedUnfairLock(initialState: [String: Found]())
        for site in Set(sites.compactMap(Self.origin(of:))) where icons[site]?.image == nil {
            let file = Self.file(for: site, in: folder)
            DispatchQueue.global(qos: .userInitiated).async(group: reads) {
                if case .icon(let found) = Self.read(file) { read.withLock { $0[site] = found } }
            }
        }
        preloading = (reads, read)
    }

    /// Waits for what `preload` is reading, as the first frame is drawn, and
    /// a moment at most: a slow one comes as its view asks for it (`load`).
    private func finishPreload() {
        guard let (reads, read) = preloading else { return }
        preloading = nil
        _ = reads.wait(timeout: .now() + .milliseconds(100))
        for (site, found) in read.withLock({ $0 }) { keep(found, for: site) }
    }

    /// A view shows the site's icon. One shown is never let go, so an icon
    /// on screen never blinks away.
    func show(_ site: String) {
        shown[site, default: 0] += 1
        gone.removeAll { $0 == site }
    }

    /// A view showing the site's icon went. Once none does, its icon is kept
    /// among the last `goneLimit` so gone, and let go after them: read from
    /// disk again should it be shown again.
    func hide(_ site: String) {
        guard let count = shown[site] else { return }
        shown[site] = count > 1 ? count - 1 : nil
        guard count == 1 else { return }
        gone.append(site)
        if gone.count > Self.goneLimit { icons[gone.removeFirst()]?.image = nil }
    }

    /// The site's /favicon.ico, or `icon` when the page names its own; that
    /// one is tried even after /favicon.ico failed. Not `keep`, as for an
    /// incognito window, it is fetched leaving nothing on disk, and kept
    /// only while Nerda runs.
    func load(_ site: String, icon named: URL? = nil, keep: Bool = true) async {
        // Two rows asking for the same site share one fetch.
        if let task = inFlight[site] { await task.value }
        let icon = icon(site)
        guard icon.image == nil, named != nil || !icon.failed,
              let url = named ?? URL(string: site + "/favicon.ico") else { return }

        let task = Task {
            let file = folder.map { Self.file(for: site, in: $0) }
            if named == nil, let file {
                switch await Task.detached(priority: .userInitiated, operation: { Self.read(file) }).value {
                case .icon(let found): self.keep(found, for: site); return
                case .failed: icon.failed = true; return
                case nil: break
                }
            }
            let fetched = try? await (keep ? Self.session : Self.ephemeral).data(from: url)
            if let (data, _) = fetched, let found = await Task.detached(priority: .userInitiated, operation: { Self.decode(data) }).value {
                self.keep(found, for: site)
                if keep, let file { await Self.write(found.smaller ?? data, to: file) }
            } else {
                icon.failed = true
                // Kept on disk, as an empty file, only when the site answered
                // without one: offline, it is asked again next time.
                if keep, named == nil, fetched != nil, let file { await Self.write(Data(), to: file) }
            }
        }
        inFlight[site] = task
        await task.value
        inFlight[site] = nil
    }

    /// Fetches without keeping a second copy in a URL cache: the icon is kept
    /// here, and on disk, already.
    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        return configuration
    }())
    /// Fetches without a cache or cookies on disk.
    private static let ephemeral = URLSession(configuration: .ephemeral)

    /// How long a site found without an icon is left before it is asked again.
    nonisolated static let retryAfter: TimeInterval = 7 * 24 * 60 * 60

    nonisolated private static func file(for site: String, in folder: URL) -> URL {
        folder.appending(path: site.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? site)
    }

    nonisolated private static func write(_ data: Data, to file: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }.value
    }

    nonisolated private enum Kept { case icon(Found), failed }

    /// What is kept on disk for a site: its icon, or, as an empty file, that
    /// it had none when last asked, lately. An icon kept big (by Nerda before
    /// they were drawn down) is written back smaller.
    nonisolated private static func read(_ file: URL) -> Kept? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if data.isEmpty {
            let asked = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return asked.map { -$0.timeIntervalSinceNow < retryAfter } == true ? .failed : nil
        }
        guard let found = decode(data) else { return nil }
        if let smaller = found.smaller { try? smaller.write(to: file, options: .atomic) }
        return .icon(found)
    }

    /// An icon, its colours, and when it came bigger than it is ever shown,
    /// the smaller copy to keep on disk in its place.
    nonisolated struct Found: Sendable {
        let image: NSImage
        let tint: Tint?
        let smaller: Data?
    }

    /// An icon from its bytes, drawn down if big. Off the main thread: a page
    /// listing many sites (the history page) otherwise read and decoded each
    /// one's icon there, as its line came into view.
    nonisolated static func decode(_ data: Data) -> Found? {
        guard let image = NSImage(data: data) else { return nil }
        let small = shrunk(image)
        return Found(image: small ?? image, tint: Tint(small ?? image), smaller: small?.tiffRepresentation(using: .lzw, factor: 0))
    }

    /// The largest an icon is shown, in points: a tab's, at 16.
    nonisolated static let side: CGFloat = 16

    /// An icon bigger than it is ever shown (a 1024-pixel PNG is 4 MB once
    /// decoded, for 16 points), drawn down to `side`: 32 pixels, for a 2×
    /// screen, and 16, for a 1× one. Each drawn from the size it has nearest,
    /// so a 16-pixel version drawn for that size stays as it is. nil for one
    /// small already.
    nonisolated static func shrunk(_ image: NSImage) -> NSImage? {
        let largest = image.representations.map { $0 is NSBitmapImageRep ? max($0.pixelsWide, $0.pixelsHigh) : .max }.max() ?? 0
        guard CGFloat(largest) > side * 2, image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = side / max(image.size.width, image.size.height)
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let small = NSImage(size: size)
        for density in [1.0, 2.0] {
            let rect = CGRect(x: 0, y: 0, width: size.width * density, height: size.height * density)
            guard let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            // Drawn by the image, in pixels, so it picks its version for that
            // many pixels, as it does on screen.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            guard let drawn = context.makeImage() else { return nil }
            let rep = NSBitmapImageRep(cgImage: drawn)
            rep.size = size
            small.addRepresentation(rep)
        }
        return small
    }

    private func keep(_ found: Found, for site: String) {
        let icon = icon(site)
        icon.image = found.image
        icon.tint = found.tint
        icon.failed = false
    }
}

/// The colours of a site's icon, for its pinned tile to wear while on screen:
/// its hues (Google's four, YouTube's red), or for a dark icon without any
/// (GitHub's), its black. A light grey one has none to give.
nonisolated struct Tint: Sendable {
    let colors: [NSColor]
    /// No hues: `colors` is the icon's one grey.
    let isGrey: Bool
    /// A dark mark with nothing behind it (GitHub's cat), which can be drawn
    /// in any colour, and must be light to show on a dark tile.
    let isMark: Bool

    init?(_ image: NSImage) {
        // Small: the colours are all that's wanted, not the detail.
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Twelve hues round the wheel, each the sum of the pixels that fall in it.
        var hues = Array(repeating: (red: 0.0, green: 0.0, blue: 0.0, count: 0), count: 12)
        var brightness = 0.0, opaque = 0, colored = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            let (red, green, blue) = (Double(pixels[i]) / 255 / alpha, Double(pixels[i + 1]) / 255 / alpha,
                                      Double(pixels[i + 2]) / 255 / alpha)
            let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            opaque += 1
            brightness += color.brightnessComponent
            guard color.saturationComponent > 0.4, color.brightnessComponent > 0.3 else { continue }
            colored += 1
            let hue = Int(color.hueComponent * 12) % 12
            hues[hue].red += red
            hues[hue].green += green
            hues[hue].blue += blue
            hues[hue].count += 1
        }
        guard opaque > 0 else { return nil }

        // A speck of colour on a grey icon doesn't make it colourful, nor one stray pixel a hue.
        if colored * 10 >= opaque {
            colors = hues.filter { $0.count * 10 >= colored }.map { hue in
                let count = Double(hue.count)
                return NSColor(srgbRed: hue.red / count, green: hue.green / count, blue: hue.blue / count, alpha: 1)
            }
            isGrey = false
            isMark = false
        } else {
            let grey = brightness / Double(opaque)
            guard grey < 0.5 else { return nil }
            colors = [NSColor(white: grey, alpha: 1)]
            isGrey = true
            // Most of it see-through: a mark alone, not one on a square of its own.
            isMark = opaque * 10 < side * side * 7
        }
    }
}

/// A site's icon on a light plate, so dark marks (GitHub's) still read on dark
/// glass; or bare, as on a pinned tile, with such a mark drawn in the text's
/// colour instead. Empty while it arrives, then fades in; a globe if there is none.
struct Favicon: View {
    let site: URL?
    var size: CGFloat = 16
    var plate = true

    private var store: Favicons { .shared }
    @Environment(\.incognito) private var incognito

    var body: some View {
        let origin = Favicons.origin(of: site)
        let icon = origin.map { store.icon($0) }
        let image = icon?.image
        let recolored = !plate && icon?.tint?.isMark == true

        ZStack {
            if let image {
                Image(nsImage: image)
                    .renderingMode(recolored ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(Palette.ink)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else if icon?.failed ?? true {
                Image(systemName: "globe")
                    .foregroundStyle(plate ? AnyShapeStyle(.black.opacity(0.5)) : AnyShapeStyle(Palette.muted))
            }
        }
        .frame(width: size + (plate ? 8 : 0), height: size + (plate ? 8 : 0))
        .background(plate ? .white.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: origin) {
            if let origin { await store.load(origin, keep: !incognito) }
        }
        .onAppear { origin.map(store.show) }
        .onDisappear { origin.map(store.hide) }
        .onChange(of: origin) { old, new in
            old.map(store.hide)
            new.map(store.show)
        }
    }
}
