import SwiftUI

/// A tab's card, while the pointer rests on it, in the sidebar or across the
/// top: the top of its page (not for the one on screen, which is already in
/// sight), its title and site, and the memory its page takes, as Chrome's
/// hover cards show. An awake page is pictured as it is now; a sleeping one
/// as it went to sleep, and says it sleeps.
struct TabPeek: View {
    let tab: Tab
    let selected: Bool

    static let width: CGFloat = 260
    /// Of the picture, across to down.
    static let aspect: CGFloat = 16 / 10

    @State private var look: NSImage?
    @State private var memory: UInt64?

    private var host: String? {
        guard tab.hasPage, let host = tab.site?.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A picture there is, or is on its way: room is kept for it meanwhile.
    private var pictured: Bool { !selected && tab.hasPage && (!tab.isAsleep || tab.look != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pictured {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                Color.clear
                    .aspectRatio(Self.aspect, contentMode: .fit)
                    .overlay(alignment: .top) {
                        if let look {
                            Image(nsImage: look)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        }
                    }
                    .background(Palette.hover)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Palette.rim))
                    .padding([.horizontal, .top], 6)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if let host {
                    Text(host)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                if tab.hasPage, tab.isAsleep {
                    Label("Sleeping", systemImage: "moon.zzz")
                        .padding(.top, 4)
                } else if let memory {
                    Label("Memory usage: \(memory >> 20) MB", systemImage: "memorychip")
                        .padding(.top, 4)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.ground)
                .strokeBorder(Palette.hairline)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        )
        .animation(.easeOut(duration: 0.12), value: look)
        // Anew for each tab the card moves on to: the last one's picture
        // would otherwise show under this one's title.
        .task(id: tab.id) {
            look = pictured ? await tab.snapshot() ?? tab.look : nil
            // Kept up while it shows: a page's memory moves as it works.
            while !Task.isCancelled {
                memory = tab.memory
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Puts its one card at `at` in the space it is given, moved back along
/// `clamping` where it would run past that space's end.
struct PeekPlacement: Layout {
    let at: CGPoint
    let clamping: Axis.Set
    private static let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(.unspecified)
        var origin = CGPoint(x: bounds.minX + at.x, y: bounds.minY + at.y)
        if clamping.contains(.horizontal) { origin.x = max(min(origin.x, bounds.maxX - size.width - Self.margin), bounds.minX) }
        if clamping.contains(.vertical) { origin.y = max(min(origin.y, bounds.maxY - size.height - Self.margin), bounds.minY) }
        card.place(at: origin, proposal: ProposedViewSize(size))
    }
}

extension View {
    /// The tab under the pointer (`hovered`) as the one whose card shows
    /// (`peeked`): the first once the pointer has rested on it half a
    /// second, as a tooltip; while one shows, the next at once. Off the tabs
    /// for a moment (the gap between two), the card stays. A menu opening
    /// (the tab's, right-clicked) puts it away, until the pointer moves on.
    func peeking(_ hovered: Tab.ID?, _ peeked: Binding<Tab.ID?>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            peeked.wrappedValue = nil
        }
        .task(id: hovered) {
            guard let hovered else {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled { peeked.wrappedValue = nil }
                return
            }
            if peeked.wrappedValue == nil {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            peeked.wrappedValue = hovered
        }
    }
}
