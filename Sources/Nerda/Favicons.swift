import AppKit
import SwiftUI

/// Site icons, fetched once and kept for the rest of the run, so a row that
/// appears again draws its icon in its first frame instead of waiting on the
/// network. Between runs URLSession's own disk cache answers the fetch.
@Observable
final class Favicons {
    static let shared = Favicons()

    // ponytail: unbounded, fine for a handful of sites (a few KB each); bound it
    // (LRU) once history feeds it hundreds of hosts.
    private(set) var images: [String: NSImage] = [:]
    private(set) var failed: Set<String> = []
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
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                images[site] = image
                failed.remove(site)
            } else {
                failed.insert(site)
            }
        }
        inFlight[site] = task
        await task.value
        inFlight[site] = nil
    }
}

/// A site's icon on a light plate, so dark marks (GitHub's) still read on dark
/// glass. Empty while it arrives, then fades in; a globe if there is none.
struct Favicon: View {
    let site: URL?
    var size: CGFloat = 16

    private var store: Favicons { .shared }

    var body: some View {
        let origin = Favicons.origin(of: site)
        let image = origin.flatMap { store.images[$0] }

        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else if origin.map(store.failed.contains) ?? true {
                Image(systemName: "globe")
                    .foregroundStyle(.black.opacity(0.5))
            }
        }
        .frame(width: size + 8, height: size + 8)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: origin) {
            if let origin { await store.load(origin) }
        }
    }
}
