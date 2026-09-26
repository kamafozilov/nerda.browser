import SwiftUI

/// A tab's card, while the pointer rests on it, in the sidebar or across the
/// top: the top of its page (not for the one on screen, which is already in
/// sight), its title and site, and the memory its page takes, as Chrome's
/// hover cards show. An awake page is pictured as it is now; a sleeping one
/// as it went to sleep, and says it sleeps.
struct TabPeek: View {
    let tab: Tab
    /// The top of its page, taken before the card shows (`peeking`), so the
    /// card comes with it in place.
    let look: NSImage?

    static let width: CGFloat = 260
    /// Of the picture, across to down.
    static let aspect: CGFloat = 16 / 10

    private var host: String? {
        guard tab.hasPage, let host = tab.site?.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The picture a card for `tab` shows: none for the one on screen, which
    /// is already in sight; an awake page as it is now, a sleeping one as it
    /// went to sleep.
    static func look(of tab: Tab, selected: Bool) async -> NSImage? {
        guard !selected, tab.hasPage else { return nil }
        return await tab.snapshot() ?? tab.look
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let look {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                Color.clear
                    .aspectRatio(Self.aspect, contentMode: .fit)
                    .overlay(alignment: .top) {
                        Image(nsImage: look)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
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
                } else {
                    // Kept up while it shows: a page's memory moves as it works.
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        if let memory = tab.memory {
                            Label("Memory usage: \(memory >> 20) MB", systemImage: "memorychip")
                                .padding(.top, 4)
                        }
                    }
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
    }
}

/// The tab whose card shows, with its picture (`TabPeek.look`).
struct Peek {
    let id: Tab.ID
    let look: NSImage?
}

/// Puts its one card's `anchor` at `at` in the space it is given, moved back
/// along `clamping` where it would run past that space's ends.
struct PeekPlacement: Layout {
    let at: CGPoint
    var anchor: UnitPoint = .topLeading
    let clamping: Axis.Set
    private static let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(.unspecified)
        var origin = CGPoint(x: bounds.minX + at.x - anchor.x * size.width,
                             y: bounds.minY + at.y - anchor.y * size.height)
        if clamping.contains(.horizontal) { origin.x = max(min(origin.x, bounds.maxX - size.width - Self.margin), bounds.minX + Self.margin) }
        if clamping.contains(.vertical) { origin.y = max(min(origin.y, bounds.maxY - size.height - Self.margin), bounds.minY + Self.margin) }
        card.place(at: origin, proposal: ProposedViewSize(size))
    }
}

/// The tab the pointer is on, in the sidebar or across the top. Out of their
/// sight: only `PeekWatch` reads it, so the pointer going from tab to tab
/// has that alone worked out again, not every tab's row.
@Observable
final class Hovered {
    var id: Tab.ID?
}

/// Keeps the card to the tab under the pointer (see `peeking`), drawing nothing.
struct PeekWatch: View {
    let browser: Browser
    let hovered: Hovered
    @Binding var peeked: Peek?

    var body: some View {
        Color.clear.peeking(browser.tabs.first { $0.id == hovered.id }, $peeked, selected: browser.selectedID)
    }
}

extension View {
    /// The tab under the pointer (`hovered`) as the one whose card shows
    /// (`peeked`): the first once the pointer has rested on it 0.7 s,
    /// as a tooltip; while one shows, the next at once. Off the tabs
    /// for a moment (the gap between two), the card stays. A menu opening
    /// (the tab's, right-clicked) puts it away, until the pointer moves on.
    /// The picture is taken in the last part of the wait, so the card shows
    /// whole: not as the pointer passes by, or sweeping it down the sidebar
    /// would have every page it crossed drawn for nothing.
    func peeking(_ hovered: Tab?, _ peeked: Binding<Peek?>, selected: Tab.ID?) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            peeked.wrappedValue = nil
        }
        .task(id: hovered?.id) {
            guard let hovered else {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled { peeked.wrappedValue = nil }
                return
            }
            let waits = peeked.wrappedValue == nil
            if waits {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            async let look = TabPeek.look(of: hovered, selected: hovered.id == selected)
            if waits {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            let shot = await look
            if Task.isCancelled { return }
            peeked.wrappedValue = Peek(id: hovered.id, look: shot)
        }
    }
}
