import SwiftUI

/// How Nerda looks, in System Settings' own order: the theme, the zoom pages
/// open at, where the tabs go, and how much of the desktop shows through.
struct AppearanceSettings: View {
    @AppStorage(Theme.key) private var theme = Theme.system
    @AppStorage(PageZoom.key) private var zoom = 1.0
    @AppStorage(TabStyle.key) private var tabStyle = TabStyle.vertical
    @AppStorage(Transparency.key) private var transparency = Transparency.transparent
    @AppStorage(AIChatsButton.key) private var showsAIChats = true

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Theme", detail: "Light, dark, or the same as macOS", icon: "circle.lefthalf.filled") {
                DropdownButton(label: theme.name, symbol: theme.symbol,
                               options: Theme.allCases.map { DropdownOption(id: $0.rawValue, title: $0.name, symbol: $0.symbol) },
                               selected: theme.rawValue) { theme = Theme(rawValue: $0) ?? .system }
            }
            SettingsRow(title: "Zoom level", detail: "The size pages open at. ⌘+ and ⌘− change it for one site", icon: "plus.magnifyingglass") {
                DropdownButton(label: PageZoom.name(zoom),
                               options: PageZoom.levels.map { DropdownOption(id: "\($0)", title: PageZoom.name($0)) },
                               selected: "\(CGFloat(zoom))") { zoom = Double($0) ?? 1 }
            }
            SettingsRow(title: "Tab style", detail: "Tabs in a sidebar down the side, or in a row across the top",
                        icon: "sidebar.left", alignment: .top) {
                PicturePicker(options: TabStyle.allCases, selection: $tabStyle, name: \.name) { TabStylePicture(style: $0) }
            }
            SettingsRow(title: "Transparency", detail: "How much of your desktop shows through around the page",
                        icon: "square.on.square.dashed", alignment: .top) {
                PicturePicker(options: Transparency.allCases, selection: $transparency, name: \.name) {
                    TransparencyPicture(transparency: $0)
                }
            }
        }
        SettingsGroup(title: "New tab") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Picture", detail: "Shown behind the search field. Daily brings a new one of Nerda's each day, and + adds your own",
                            icon: "photo") { EmptyView() }
                WallpaperStrip(backdrop: .shared, glass: false)
                    .padding(.horizontal, 3)
                    .padding(.bottom, 4)
            }
        }
        SettingsGroup(title: "Sidebar") {
            SettingsRow(title: "AI chats", detail: "The button at the bottom of the sidebar that opens ChatGPT, Claude and the others",
                        icon: "sparkles") {
                SettingsToggle(title: "AI chats", isOn: $showsAIChats)
            }
        }
        .onChange(of: theme) { Theme.apply() }
        .onChange(of: zoom) { old, new in
            for window in NSApp.windows {
                (window as? BrowserWindow)?.browser.tabs.forEach { $0.defaultZoomChanged(from: old, to: new) }
            }
        }
    }
}

/// A choice shown as pictures, as System Settings shows Light and Dark: the
/// one chosen ringed in the accent colour, its name bold under it.
private struct PicturePicker<Value: Hashable, Picture: View>: View {
    let options: [Value]
    @Binding var selection: Value
    let name: (Value) -> String
    @ViewBuilder let picture: (Value) -> Picture

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                Button { selection = option } label: {
                    VStack(spacing: 5) {
                        picture(option)
                            .frame(width: 72, height: 46)
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(lineWidth: 2.5)
                                .animation(fade) { $0.foregroundStyle(chosen ? Color.accentColor : .clear) })
                        // The hidden semibold copy holds the width, so choosing
                        // an option never moves the pictures beside it.
                        Text(name(option))
                            .font(.system(size: 12, weight: .semibold))
                            .hidden()
                            .overlay(Text(name(option)).animation(fade) {
                                $0.font(.system(size: 12, weight: chosen ? .semibold : .regular))
                                    .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                            })
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name(option))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    /// Only the ring and the name fade: the page around the picker moves when
    /// the tab style changes, and the picker moves with it, in one step.
    private let fade = Animation.easeOut(duration: 0.14)
}

/// A window in little, on the desktop through its glass: its tabs down a
/// sidebar, or across the top, the one on screen lit, and the page's card.
private struct TabStylePicture: View {
    let style: TabStyle

    var body: some View {
        let line = Palette.muted.opacity(0.7)
        ZStack(alignment: .topLeading) {
            Desktop()
            Rectangle().fill(.regularMaterial)
            HStack(spacing: 1.5) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }
            .frame(height: 3.5)
            .offset(x: 4, y: 4)
            if style == .vertical {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Palette.ink.opacity(0.6)).frame(width: 11, height: 2)
                        .padding(.horizontal, 2.5).padding(.vertical, 2)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                    ForEach([9.0, 12, 8], id: \.self) { width in
                        Capsule().fill(line).frame(width: width, height: 2).padding(.leading, 2.5)
                    }
                }
                .offset(x: 3, y: 12)
                card(corners: 3)
                    .padding([.top, .bottom, .trailing], 2)
                    .padding(.leading, 22)
            } else {
                UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5, style: .continuous)
                    .fill(Palette.ground)
                    .frame(width: 18, height: 8)
                    .offset(x: 19, y: 3)
                Capsule().fill(line).frame(width: 10, height: 2).offset(x: 42, y: 6)
                card(corners: 0)
                    .padding(.top, 11)
            }
        }
    }

    /// The page, under its address bar.
    private func card(corners: CGFloat) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: corners, bottomTrailingRadius: corners,
                               topTrailingRadius: corners, style: .continuous)
            .fill(Palette.ground)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    Capsule().fill(Palette.muted.opacity(0.7)).frame(width: 5, height: 2)
                    Capsule().fill(Palette.muted.opacity(0.35)).frame(width: 22, height: 2)
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            }
    }
}

/// The desktop through a card of glass, clear, or tinted most of the way to solid.
private struct TransparencyPicture: View {
    let transparency: Transparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Desktop()
            .overlay(alignment: .topLeading) {
                Group {
                    if transparency == .tinted {
                        shape.fill(.regularMaterial).overlay(shape.fill(Palette.tint))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .frame(width: 64, height: 42)
                // Running off the bottom right, as a window bigger than the picture.
                .offset(x: 16, y: 12)
            }
    }
}
