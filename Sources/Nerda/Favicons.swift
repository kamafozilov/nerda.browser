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

    // ponytail: /favicon.ico only; read the page's <link rel="icon"> once pages load.
    func load(_ host: String) async {
        guard images[host] == nil, !failed.contains(host) else { return }
        // Two rows asking for the same site share one fetch.
        if let task = inFlight[host] { return await task.value }

        let task = Task {
            let url = URL(string: "https://\(host)/favicon.ico")!
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                images[host] = image
            } else {
                failed.insert(host)
            }
        }
        inFlight[host] = task
        await task.value
        inFlight[host] = nil
    }
}

/// A site's icon on a light plate, so dark marks (GitHub's) still read on dark
/// glass. Empty while it arrives, then fades in; a globe if there is none.
struct Favicon: View {
    let host: String
    var size: CGFloat = 16

    private var store: Favicons { .shared }

    var body: some View {
        let image = store.images[host]

        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else if store.failed.contains(host) {
                Image(systemName: "globe")
                    .foregroundStyle(.black.opacity(0.5))
            }
        }
        .frame(width: size + 8, height: size + 8)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: host) { await store.load(host) }
    }
}
