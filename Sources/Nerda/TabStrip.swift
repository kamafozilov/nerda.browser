import SwiftUI

/// The tabs across the top of the window, in place of the sidebar (Settings ›
/// Appearance › Tab style), as in Chrome and Safari: past the traffic lights,
/// the pinned sites' icons, then the tabs, sharing the width out between them,
/// and the button for another after the last. The tab on screen wears its
/// address bar's colour and the card's edge, and flares out into the card, as
/// one piece with it. At the far end, the downloads and the app's menu.
///
/// Tabs and pinned sites are dragged into another order; a tab let go on the
/// pinned sites is pinned there, a pinned site let go among the tabs unpinned.
struct TabStrip: View {
    let browser: Browser
    @Binding var downloadsShown: Bool
    @Binding var menuShown: Bool

    /// As tall as a compact toolbar makes the title bar, so the traffic lights
    /// sit in its middle (see `TabStyle.toolbarStyle`).
    static let height: CGFloat = 40
    /// From just under the window's top down to the card.
    static let tabHeight: CGFloat = 36
    /// How far the tab on screen flares out each side at its foot.
    static let flare: CGFloat = 8
    /// Past the traffic lights.
    private static let lights: CGFloat = 80
    /// A tab's share of the width, within these.
    private static let widths: ClosedRange<CGFloat> = 28...220
    /// A pinned site's icon, and the room between two.
    static let icon: CGFloat = 30
    private static let iconGap: CGFloat = 2
    nonisolated private static let space = "strip"

    @State private var dragged: Drag?
    /// Where what is dragged would go in the other group, while it is over
    /// that: a tab over the pinned sites, among them, where a gap opens for
    /// it; a pinned site over the tabs, among those. Set only when that changes.
    @State private var landing: Landing?
    /// Where the pointer is while dragging, in the strip's space. Only the
    /// copy under it reads it, so a move redraws that copy, not every tab.
    @State private var pointer = Pointer()
    @State private var layout = Layout()
    /// The tab the pointer is on, and the one whose card shows (`TabPeek`).
    @State private var hovered: Tab.ID?
    @State private var peeked: Peek?
    @Environment(\.colorScheme) private var scheme

    /// A tab or pinned site being dragged.
    private struct Drag {
        let id: Tab.ID
        /// Where the drag began: another starts afresh, even after one that
        /// never ended (its tab closed under it).
        let start: CGPoint
        /// From the middle of what was taken hold of to the pointer, across,
        /// so the same spot stays under it.
        let grab: CGFloat
    }

    private enum Landing: Equatable {
        case pins(Int), tabs(Int)
    }

    /// Where the pinned sites and the tabs are, in the strip's space, for a
    /// drag to tell what it is over. Out of SwiftUI's sight, as the sidebar's.
    private final class Layout {
        var pins = CGRect.zero
        var tabs = CGRect.zero
    }

    var body: some View {
        HStack(spacing: 0) {
            #if DEBUG
            DevBadge()
                .padding(.trailing, 8)
            #endif
            // Incognito tabs go with their window: nothing there to keep pinned.
            if !browser.isPrivate, !pins.isEmpty || pinning {
                pinned
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
            GeometryReader { space in tabs(room: space.size.width) }
            HStack(spacing: 6) {
                DownloadsButton(browser: browser, shown: $downloadsShown, arrowEdge: .bottom)
                SidebarMenuButton(shown: $menuShown, incognito: browser.isPrivate)
            }
            .padding(.leading, 8)
        }
        .padding(.leading, Self.lights)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .coordinateSpace(.named(Self.space))
        // Moves the window, as the title bar under it would. Off the tabs,
        // right-clicked, the menu for them all: their own show on them.
        .background { Color.clear.contentShape(Rectangle()).titleBar().contextMenu { TabsMenu(browser: browser) } }
        // What is dragged follows the pointer, over everything in the strip:
        // a tab over the pinned sites turns into one, and one of those over
        // the tabs into a tab.
        .overlay(alignment: .topLeading) {
            if let tab = draggedTab {
                let asPin = tab.isPinned != (landing != nil)
                let width = asPin ? Self.icon : tabWidth > 0 ? tabWidth : Self.widths.upperBound
                Along(pointer: pointer, grab: landing == nil ? dragged?.grab ?? 0 : 0, width: width,
                      y: asPin ? Self.height / 2 : Self.height - Self.tabHeight / 2) {
                    if asPin {
                        PinnedIcon(site: tab.site, loading: false, title: tab.title, selected: true) {}
                    } else {
                        look(tab, selected: true, compact: width < 72)
                            .frame(width: width)
                            // The card's edge keeps its gap under it, wherever it is taken.
                            .anchorPreference(key: SelectedTabKey.self, value: .bounds) { $0 }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        // The card of the tab the pointer rests on, just under it, over the page.
        .overlay(alignment: .topLeading) {
            if dragged == nil, let peeked, let index = items.firstIndex(of: peeked.id), let tab = browser.tabs.first(where: { $0.id == peeked.id }) {
                PeekPlacement(at: CGPoint(x: layout.tabs.minX + CGFloat(index) * tabWidth, y: Self.height + 2),
                              clamping: .horizontal) {
                    TabPeek(tab: tab, look: peeked.id == browser.selectedID ? nil : peeked.look)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // In and out, faded; from one tab's card to the next, at once.
        .animation(.easeOut(duration: 0.12), value: peeked == nil)
        .peeking(browser.tabs.first { $0.id == hovered }, $peeked, selected: browser.selectedID)
    }

    /// What is being dragged, while it is still open.
    private var draggedTab: Tab? {
        dragged.flatMap { dragged in browser.tabs.first { $0.id == dragged.id } }
    }

    private var pins: [Tab] { Array(browser.tabs.prefix { $0.isPinned }) }
    private var rest: [Tab] { Array(browser.tabs.drop { $0.isPinned }) }
    /// The tabs, and the gap among them for a pinned site dragged over them.
    private var items: [Tab.ID?] {
        var items: [Tab.ID?] = rest.map(\.id)
        if case .tabs(let index) = landing, draggedTab != nil { items.insert(nil, at: min(index, items.count)) }
        return items
    }

    private var tabWidth: CGFloat {
        let count = items.count
        return count == 0 ? 0 : layout.tabs.width / CGFloat(count)
    }

    /// A tab with a site is being dragged: the pinned sites show, to take it,
    /// even while there are none.
    private var pinning: Bool { draggedTab.map { !$0.isPinned && $0.hasPage && $0.bookmark == nil } ?? false }

    /// The pinned sites, as icons in a group of their own. A tab dragged over
    /// them opens a gap where it would go; with none pinned yet, the group
    /// shows where to drop it, lit once it is over it.
    private var pinned: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        var items: [Tab.ID?] = pins.map(\.id)
        if case .pins(let index) = landing, draggedTab != nil, !items.isEmpty { items.insert(nil, at: min(index, items.count)) }
        return HStack(spacing: Self.iconGap) {
            if items.isEmpty {
                Image(systemName: "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(landing == nil ? Palette.muted : Palette.ink)
                    .frame(width: Self.icon, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(landing == nil ? .clear : Palette.wash))
            }
            // One list, the gap in it, so the icons make way for it.
            ForEach(items, id: \.self) { id in
                if let id, let tab = browser.tabs.first(where: { $0.id == id }) {
                    PinnedIcon(site: tab.site, loading: tab.isLoading, title: tab.title,
                               selected: id == browser.selectedID, press: { browser.select(id) }) {
                        browser.select(id)
                    }
                    // Its place stays empty while it is dragged: where it will land.
                    .opacity(dragged?.id == id ? 0 : 1)
                    .simultaneousGesture(drag(id))
                    // Back to where it was pinned, from wherever it has been since.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { browser.tabs.first { $0.id == id }?.goHome() })
                    .contextMenu { TabMenu(browser: browser, id: id) }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    Color.clear.frame(width: Self.icon, height: 26)
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.pins = $0 }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .animation(.snappy(duration: 0.2), value: landing)
    }

    /// The tabs in `room`, each an even share of it, with the + button after
    /// the last. A pinned site dragged over them opens a gap where it would go.
    private func tabs(room: CGFloat) -> some View {
        let items = items
        let room = max(room - 34, 0)
        let width = min(max(room / CGFloat(max(items.count, 1)), Self.widths.lowerBound), Self.widths.upperBound)
        let selected = items.firstIndex { $0 == browser.selectedID }
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, id in
                    if let id, let tab = browser.tabs.first(where: { $0.id == id }) {
                        // A line between two tabs, unless one is on screen, or the gap.
                        row(tab, width: width, separated: index > 0 && items[index - 1] != nil
                            && selected != index && selected != index - 1)
                    } else {
                        Color.clear.frame(width: width, height: Self.tabHeight)
                    }
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [layout] in layout.tabs = $0 }
            .animation(.snappy(duration: 0.2), value: landing)
            // ponytail: past ~60 tabs the last are cut off here; ⌘⇧A and ⌃Tab still reach them.
            .frame(width: min(CGFloat(items.count) * width, room), alignment: .leading)
            .clipShape(Rectangle().inset(by: -Self.flare))
            .frame(height: Self.height, alignment: .bottom)
            BarButton(icon: "plus", help: "New Tab  ⌘T", action: browser.newTab)
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
    }

    private func row(_ tab: Tab, width: CGFloat, separated: Bool) -> some View {
        let id = tab.id
        let selected = id == browser.selectedID
        return look(tab, selected: selected, separated: separated, compact: width < 72)
            .frame(width: width)
            .opacity(dragged?.id == id ? 0 : 1)
            // Where the card's edge leaves room for it to run into the card.
            .anchorPreference(key: SelectedTabKey.self, value: .bounds) { selected && dragged?.id != id ? $0 : nil }
            // Its flares over its neighbours.
            .zIndex(selected ? 1 : 0)
            // A sleeping tab's site is connected to on the way to a click on it.
            .onHover { over in
                if over { hovered = id } else if hovered == id { hovered = nil }
                guard over, let tab = browser.tabs.first(where: { $0.id == id }), tab.isAsleep,
                      let site = tab.site else { return }
                Tab.preconnect(to: site)
            }
            .simultaneousGesture(drag(id))
            .contextMenu { TabMenu(browser: browser, id: id) }
            .transition(.opacity)
    }

    /// A tab as it is drawn, in its place or under the pointer.
    private func look(_ tab: Tab, selected: Bool, separated: Bool = false, compact: Bool) -> some View {
        let id = tab.id
        return StripTab(
            icon: tab.settings != nil ? "gearshape" : tab.showsHistory ? "clock.arrow.circlepath" : "globe",
            site: tab.site,
            loading: tab.isLoading,
            title: tab.title,
            selected: selected,
            separated: separated,
            compact: compact,
            close: { withAnimation(.slide) { browser.close(id) } },
            // A new tab, or the settings, keeps the name it has.
            rename: tab.hasPage ? { name in
                if let name { browser.rename(id, to: name) }
            } : nil,
            press: { browser.select(id) }
        ) {
            browser.select(id)
        }
        // Light or dark to suit its page's colour, as the address bar it runs into.
        .environment(\.colorScheme, selected ? tab.color.map(AddressBar.colorScheme) ?? scheme : scheme)
        // Outside that, so its edge is the card's, whatever the page's colour.
        .background { if selected { TabGround(ground: AddressBar.ground(of: tab)) } }
    }

    /// Dragging a tab or pinned site, by the id alone (see the rows).
    private func drag(_ id: Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged?.start != value.startLocation {
                    dragged = start(id, at: value.startLocation)
                    landing = nil
                }
                pointer.at = value.location
                follow(id)
            }
            .onEnded { _ in drop(id) }
    }

    private func start(_ id: Tab.ID, at point: CGPoint) -> Drag? {
        middle(of: id).map { Drag(id: id, start: point, grab: point.x - $0) }
    }

    /// Across, the middle of a tab's or pinned site's place in its group.
    private func middle(of id: Tab.ID) -> CGFloat? {
        if let index = pins.firstIndex(where: { $0.id == id }) {
            return layout.pins.minX + CGFloat(index) * (Self.icon + Self.iconGap) + Self.icon / 2
        }
        guard let index = rest.firstIndex(where: { $0.id == id }) else { return nil }
        return layout.tabs.minX + (CGFloat(index) + 0.5) * tabWidth
    }

    /// As the middle of what is dragged passes over another of its group, it
    /// takes its place there, and the rest make way. Over the other group,
    /// the pointer shows where it would go (`landing`): moved there at once,
    /// it would lose the drag with the view it leaves.
    private func follow(_ id: Tab.ID) {
        guard let dragged, let tab = browser.tabs.first(where: { $0.id == id }) else { return }
        let x = pointer.at.x, middle = x - dragged.grab
        let icon = Self.icon + Self.iconGap
        var over: Landing?
        if tab.isPinned, x >= layout.tabs.minX {
            over = .tabs(min(Self.index(at: x, from: layout.tabs.minX, width: tabWidth), rest.count))
        } else if !tab.isPinned, !browser.isPrivate, tab.hasPage, x < layout.tabs.minX {
            over = .pins(min(Self.index(at: x, from: layout.pins.minX, width: icon), pins.count))
        } else {
            let index = tab.isPinned ? Self.index(at: middle, from: layout.pins.minX, width: icon)
                : Self.index(at: middle, from: layout.tabs.minX, width: tabWidth)
            withAnimation(.snappy(duration: 0.2)) { browser.move(id, pinned: tab.isPinned, to: index) }
        }
        if over != landing { landing = over }
    }

    /// Let go over its own group, it slides into its place, and only there
    /// takes it back; over the other group, it goes there: pinned, or unpinned.
    private func drop(_ id: Tab.ID) {
        let landing = landing
        if landing == nil, let drag = dragged, let middle = middle(of: id) {
            withAnimation(.snappy(duration: 0.18)) {
                pointer.at.x = middle + drag.grab
            } completion: {
                // Unless another drag has begun since.
                if dragged?.start == drag.start { dragged = nil }
            }
            return
        }
        withAnimation(.slide) {
            dragged = nil
            self.landing = nil
            switch landing {
            case .pins(let index): browser.move(id, pinned: true, to: index)
            case .tabs(let index): browser.move(id, pinned: false, to: index)
            case nil: break
            }
        }
    }

    /// Which of a row of `width`-wide places from `from` is under `x`: the
    /// first before them all.
    private static func index(at x: CGFloat, from: CGFloat, width: CGFloat) -> Int {
        width > 0 ? max(Int(((x - from) / width).rounded(.down)), 0) : 0
    }
}

/// What is dragged, under the pointer, along the strip: the one view a move of
/// the pointer draws again. Kept from going off its start.
private struct Along<Content: View>: View {
    let pointer: Pointer
    let grab: CGFloat
    let width: CGFloat
    let y: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content.position(x: max(pointer.at.x - grab, width / 2), y: y)
    }
}

/// One tab across the top: its icon and title, and while the pointer is on
/// it, or it is on screen, the button that closes it.
private struct StripTab: View {
    let icon: String
    var site: URL?
    var loading = false
    let title: String
    let selected: Bool
    var separated = false
    /// Too narrow for a title: the icon alone.
    var compact = false
    let close: () -> Void
    /// As a sidebar row's (see there).
    var rename: ((String?) -> Void)?
    var press: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false
    @State private var renaming = false

    var body: some View {
        let closes = !compact && !renaming && (hovering || selected)
        Button(action: action) {
            HStack(spacing: 8) {
                TabIcon(site: site, loading: loading, fallback: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                if renaming {
                    RenameField(title: title) { name in
                        renaming = false
                        rename?(name)
                    }
                } else if !compact {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.leading, compact ? 0 : 12)
            // Room for the close button, so a long title stops short of it.
            .padding(.trailing, closes ? 32 : compact ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            // Level with the traffic lights, above the foot the tab runs out into.
            .padding(.bottom, 4)
            .frame(height: TabStrip.tabHeight)
            .background {
                if hovering, !selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.hover)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in press?() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if rename != nil { renaming = true } })
        // Over the tab rather than inside it, so a click on it closes the tab
        // without also selecting it.
        .overlay(alignment: .trailing) {
            if closes {
                CloseButton(action: close)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
            }
        }
        .overlay(alignment: .leading) {
            if separated {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 16)
                    .padding(.bottom, 4)
            }
        }
        // After the overlays, so moving onto the close button still counts as
        // being over the tab.
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Where the tab on screen is across the top, for the card's edge to leave a
/// gap under it (see `BrowserView`), in its place or under the pointer.
struct SelectedTabKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Under the tab on screen: filled in the card's ground, down to the card, and
/// edged in the card's hairline, which leaves a gap for it, so the two read
/// as one piece.
private struct TabGround: View {
    let ground: Color

    var body: some View {
        ZStack {
            TabShape(flare: TabStrip.flare)
                .fill(ground)
            // Its ends meet the middle of the card's edge.
            TabShape(flare: TabStrip.flare, open: true)
                .stroke(BrowserView.edge, lineWidth: 1)
                .padding(.bottom, -0.5)
        }
        .padding(.horizontal, -TabStrip.flare)
    }
}

/// The card's edge, but for a gap across its top: where the tab on screen,
/// flares and all, runs into it.
/// Moved with an animation (a tab sliding home), the gap slides with it.
nonisolated struct EdgeGap: Shape {
    /// Empty, for no gap.
    var gap: CGRect

    var animatableData: CGRect.AnimatableData {
        get { gap.animatableData }
        set { gap.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if gap.width > 0 { path.addRect(CGRect(x: gap.minX, y: rect.minY, width: gap.width, height: gap.maxY + 2 - rect.minY)) }
        return path
    }
}

/// The tab on screen: its upper corners rounded, its foot flaring out each
/// side into the card under it, as Chrome's does. `flare` wider each side
/// than the tab. Open, its outline without the foot.
nonisolated private struct TabShape: Shape {
    let flare: CGFloat
    var open = false
    var radius: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + flare, right = rect.maxX - flare
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left, y: rect.minY), radius: flare)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: flare)
        if !open { path.closeSubpath() }
        return path
    }
}

/// A pinned site across the top: its icon alone, its name in a tooltip. Its
/// icon stays while it loads, as a tile's does (see `PinnedTile`).
private struct PinnedIcon: View {
    let site: URL?
    let loading: Bool
    let title: String
    let selected: Bool
    var press: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Button(action: action) {
            TabIcon(site: site, loading: loading && Favicons.origin(of: site).flatMap { Favicons.shared.images[$0] } == nil,
                    size: 16)
                .frame(width: TabStrip.icon, height: 26)
                .background(shape.fill(selected ? Palette.wash : hovering ? Palette.hover : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in press?() })
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}
