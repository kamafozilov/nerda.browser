import SwiftUI

/// At the bottom of a new tab, in the middle: a button that opens, above it,
/// a strip of the pictures to choose from, the one showing marked. It scrolls
/// sideways, with the trackpad or the arrows at its ends; a click anywhere
/// else puts it away.
struct WallpaperPicker: View {
    private let backdrop = Backdrop.shared
    @State private var open = false
    @State private var hovering = false

    private static let motion = Animation.spring(duration: 0.3, bounce: 0.12)

    var body: some View {
        ZStack(alignment: .bottom) {
            if open {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Self.motion) { open = false } }
            }
            VStack(spacing: 10) {
                if open {
                    WallpaperStrip(backdrop: backdrop)
                        .padding(.horizontal, 16)
                        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                }
                Button {
                    withAnimation(Self.motion) { open.toggle() }
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(open || hovering ? Palette.ink : Palette.muted)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassPanel(cornerRadius: 17, tint: 0.5)
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                .onHover { hovering = $0 }
                .help("Change Wallpaper")
                .accessibilityLabel("Change Wallpaper")
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The pictures side by side on glass, opened on the one showing. Past its
/// ends, what is left fades out and an arrow scrolls to it.
private struct WallpaperStrip: View {
    let backdrop: Backdrop

    @State private var position: ScrollPosition
    /// The last scroll, for the arrows. Kept out of the view's state, so
    /// scrolling doesn't make the strip again every frame; only reaching or
    /// leaving an end (`before`, `after`) does.
    @State private var scrolled = Scrolled()
    @State private var before = false
    @State private var after = false
    /// The tile under the pointer: one of yours shows how to remove it.
    @State private var hovered: Wallpaper?

    private final class Scrolled {
        var geometry: ScrollGeometry?
    }

    init(backdrop: Backdrop) {
        self.backdrop = backdrop
        // There from the first frame, rather than scrolled to as it opens.
        _position = State(initialValue: ScrollPosition(id: backdrop.wallpaper, anchor: .center))
    }

    static let tile = CGSize(width: 112, height: 70)
    private static let gap: CGFloat = 8
    private static let inset: CGFloat = 10
    private static let fade: CGFloat = 28

    var body: some View {
        let count = CGFloat(backdrop.wallpapers.count + 1)
        let width = count * Self.tile.width + (count - 1) * Self.gap + 2 * Self.inset

        ScrollView(.horizontal) {
            HStack(spacing: Self.gap) {
                ForEach(backdrop.wallpapers, id: \.self) { wallpaper in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { backdrop.wallpaper = wallpaper }
                    } label: {
                        WallpaperTile(image: backdrop.file(of: wallpaper).flatMap { backdrop.thumbnails[$0] },
                                      daily: wallpaper == .daily, selected: wallpaper == backdrop.wallpaper)
                    }
                    .buttonStyle(.plain)
                    .help(Backdrop.title(of: wallpaper))
                    // Beside the tile's button, not in it, so a click on it
                    // only removes.
                    .overlay(alignment: .topLeading) {
                        if case .chosen(let name) = wallpaper, hovered == wallpaper { removeButton(name) }
                    }
                    .onHover { inside in
                        if inside { hovered = wallpaper } else if hovered == wallpaper { hovered = nil }
                    }
                }
                Button(action: backdrop.askForPicture) { AddTile() }
                    .buttonStyle(.plain)
                    .help("Choose a Picture…")
            }
            .scrollTargetLayout()
            .padding(Self.inset)
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, now in
            scrolled.geometry = now
            let x = now.contentOffset.x, overflow = now.contentSize.width - now.containerSize.width
            if before != (x > 1) { before = x > 1 }
            if after != (x < overflow - 1) { after = x < overflow - 1 }
        }
        // What runs past either end fades out, so it reads as more to scroll to.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: before ? Self.fade : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: after ? Self.fade : 0)
            }
        }
        .overlay(alignment: .leading) {
            if before { arrow("chevron.left") { scroll(by: -1) } }
        }
        .overlay(alignment: .trailing) {
            if after { arrow("chevron.right") { scroll(by: 1) } }
        }
        .animation(.easeOut(duration: 0.15), value: before)
        .animation(.easeOut(duration: 0.15), value: after)
        .frame(maxWidth: min(width, 620))
        .frame(height: Self.tile.height + 2 * Self.inset)
        .glassPanel(cornerRadius: 18, tint: 0.5)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }

    /// Most of a strip's width at a time, so the tile at the edge stays in sight.
    private func scroll(by pages: CGFloat) {
        guard let now = scrolled.geometry else { return }
        let overflow = now.contentSize.width - now.containerSize.width
        let x = min(max(0, now.contentOffset.x + pages * now.containerSize.width * 0.8), overflow)
        withAnimation(.spring(duration: 0.35, bounce: 0)) { position.scrollTo(x: x) }
    }

    private func removeButton(_ name: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { backdrop.remove(name) }
            hovered = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Remove Picture")
        .accessibilityLabel("Remove Picture")
        .transition(.opacity)
    }

    private func arrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: 13, tint: 0.75)
        .padding(.horizontal, 6)
        .transition(.opacity)
    }
}

/// One picture, small. Daily shows today's, and says what it is.
private struct WallpaperTile: View {
    let image: CGImage?
    let daily: Bool
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            // Until the small copy is made.
            Palette.hover
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: WallpaperStrip.tile.width, height: WallpaperStrip.tile.height)
            }
            if daily {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                Label("Daily", systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
            }
        }
        .frame(width: WallpaperStrip.tile.width, height: WallpaperStrip.tile.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(selected ? 0.95 : hovering ? 0.5 : 0.12), lineWidth: selected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .padding(5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hovering && !selected ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(shape)
        .onHover { hovering = $0 }
    }
}

/// The last tile: a picture of your own.
private struct AddTile: View {
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .frame(width: WallpaperStrip.tile.width, height: WallpaperStrip.tile.height)
            .background(hovering ? Palette.wash : Palette.hover, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
