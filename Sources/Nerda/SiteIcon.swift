import SwiftUI

/// A site's icon on a white tile, as the tabs have it, or, for a site Nerda
/// has no icon of, a globe on a grey one the same size.
struct SiteIcon: View {
    let host: String
    let size: CGFloat

    var body: some View {
        let site = URL(string: "https://\(host)")
        // Drawn until it is known there is none: Favicon loads it.
        let none = Favicons.origin(of: site).map { Favicons.shared.icon($0) }.map { $0.image == nil && $0.failed } ?? true
        if !none {
            Favicon(site: site, size: size)
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: size + 8, height: size + 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
