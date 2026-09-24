import AppKit
import SwiftUI

/// Site icons, fetched once and kept, so a row that appears again draws its
/// icon in its first frame instead of waiting on the network. Kept on disk
/// too: a tab from the last run sleeps until shown, and the icon its page
/// names (all some sites have: their /favicon.ico is empty) is only found
/// in the page.
@Observable
final class Favicons {
    static let shared = Favicons()
    static let folder = URL.applicationSupportDirectory.appending(path: "Nerda/Favicons")

    /// Where icons are kept between runs; nil keeps them to this run, as in tests.
    // ponytail: an icon once kept is never fetched again; refresh it on page
    // load if sites changing their icons turns out to matter.
    @ObservationIgnored var folder: URL?

    // ponytail: unbounded, fine for a handful of sites (a few KB each); bound it
    // (LRU) once history feeds it hundreds of hosts.
    private(set) var images: [String: NSImage] = [:]
    private(set) var failed: Set<String> = []
    /// Each icon's colours, for its site's pinned tile.
    private(set) var tints: [String: Tint] = [:]
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    /// The key an icon is kept under: scheme, host and port, so a local server
    /// (http://localhost:3000) is asked, not https://localhost. nil for
    /// addresses that have no site (file:, about:).
    nonisolated static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// The site's /favicon.ico, or `icon` when the page names its own; that
    /// one is tried even after /favicon.ico failed.
    func load(_ site: String, icon: URL? = nil) async {
        // Two rows asking for the same site share one fetch.
        if let task = inFlight[site] { await task.value }
        guard images[site] == nil, icon != nil || !failed.contains(site),
              let url = icon ?? URL(string: site + "/favicon.ico") else { return }

        let task = Task {
            let file = folder?.appending(path: site.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? site)
            if icon == nil, let file, let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                keep(image, for: site)
            } else if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                keep(image, for: site)
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
            } else {
                failed.insert(site)
            }
        }
        inFlight[site] = task
        await task.value
        inFlight[site] = nil
    }

    private func keep(_ image: NSImage, for site: String) {
        images[site] = image
        tints[site] = Tint(image)
        failed.remove(site)
    }
}

/// The colours of a site's icon, for its pinned tile to wear while on screen:
/// its hues (Google's four, YouTube's red), or for a dark icon without any
/// (GitHub's), its black. A light grey one has none to give.
nonisolated struct Tint {
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

    var body: some View {
        let origin = Favicons.origin(of: site)
        let image = origin.flatMap { store.images[$0] }
        let recolored = !plate && origin.flatMap { store.tints[$0] }?.isMark == true

        ZStack {
            if let image {
                Image(nsImage: image)
                    .renderingMode(recolored ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(Palette.ink)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else if origin.map(store.failed.contains) ?? true {
                Image(systemName: "globe")
                    .foregroundStyle(plate ? AnyShapeStyle(.black.opacity(0.5)) : AnyShapeStyle(Palette.muted))
            }
        }
        .frame(width: size + (plate ? 8 : 0), height: size + (plate ? 8 : 0))
        .background(plate ? .white.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: origin) {
            if let origin { await store.load(origin) }
        }
    }
}
