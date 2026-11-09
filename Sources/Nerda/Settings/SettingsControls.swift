import SwiftUI

/// A site in a list: its icon and name, a line on it, and what can be done to it.
struct SiteRow<Control: View>: View {
    let site: URL?
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let site { Favicon(site: site, size: 16, plate: false) }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
    }
}

/// A square that fills in the text's colour when ticked, as Aside's do,
/// rather than the system's accent-blue box.
struct SettingsCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                shape
                    .fill(configuration.isOn ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.clear))
                    .overlay(shape.strokeBorder(configuration.isOn ? .clear : Palette.muted, lineWidth: 1))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.ground)
                        }
                    }
                    .frame(width: 15, height: 15)
                configuration.label
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A row that takes you somewhere else, the whole of it a button.
struct SettingsLink: View {
    let title: String
    var detail: String?
    var icon: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title, detail: detail, icon: icon) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// The desktop the little windows sit on: blue, with light sweeping across
/// it, as macOS's own pictures.
struct Desktop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.52, green: 0.77, blue: 1), Color(red: 0.08, green: 0.3, blue: 0.86)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 80, height: 34)
                    .rotationEffect(.degrees(-24))
                    .offset(x: -18, y: 12)
                    .blur(radius: 3)
            }
            .overlay {
                Ellipse()
                    .fill(Color(red: 0.02, green: 0.16, blue: 0.62))
                    .frame(width: 70, height: 30)
                    .rotationEffect(.degrees(-28))
                    .offset(x: 26, y: 20)
                    .blur(radius: 5)
            }
    }
}

/// A dialog over the settings, which dim under it (and blur, `dialogBlur`): a click on them, or Esc
/// (when an open list isn't taking it), lets it go.
struct SettingsDialog<Content: View>: View {
    let width: CGFloat
    let escapes: Bool
    let cancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            RoundedRectangle(cornerRadius: BrowserView.cornerRadius, style: .continuous)
                .fill(.black.opacity(0.35))
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(20)
                .frame(width: width)
                .background(Palette.ground, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .accessibilityAddTraits(.isModal)
        }
        .background {
            if escapes {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }
}

/// A list a `DropdownButton` opened: where the button is, what it offers,
/// which is chosen, and what choosing does. Drawn over everything by the
/// settings (`DropdownPanel`), so no card or dialog cuts it off.
struct Dropdown {
    nonisolated static let space = "settings"

    let anchor: CGRect
    /// Under the button (to add something), or over it, the chosen one where it was.
    let below: Bool
    let options: [DropdownOption]
    let selected: String?
    let choose: (String) -> Void
    /// Something of its own in place of the options, this big (the filter
    /// lists), its right edge under the button's.
    var panel: (content: AnyView, size: CGSize)?
}

struct DropdownOption {
    let id: String
    let title: String
    /// The site whose icon it is shown with.
    var site: URL?
    /// Or the symbol.
    var symbol: String?
    /// A line under it, between it and the rest.
    var separated = false
}

extension EnvironmentValues {
    /// Where a `DropdownButton` puts its list (`dropdownHost`).
    @Entry var dropdown: Binding<Dropdown?> = .constant(nil)
}

extension View {
    /// A page under a `SettingsDialog`, out of focus, as Aside's is. Blurred
    /// itself: a material over it would show the desktop instead.
    func dialogBlur(_ open: Bool) -> some View {
        blur(radius: open ? 6 : 0)
            .animation(.easeOut(duration: 0.15), value: open)
    }

    /// Where the `DropdownButton`s in it open their lists: over all of it.
    func dropdownHost(_ dropdown: Binding<Dropdown?>) -> some View {
        coordinateSpace(.named(Dropdown.space))
            .environment(\.dropdown, dropdown)
            .overlay(alignment: .topLeading) {
                if let open = dropdown.wrappedValue { DropdownPanel(dropdown: open) { dropdown.wrappedValue = nil } }
            }
    }
}

/// A choice among several, as a button that opens them in a list: its label
/// is what is chosen (with its site's icon), or with an icon, what it does.
struct DropdownButton: View {
    let label: String
    var site: URL?
    /// The chosen one's symbol, before its name.
    var symbol: String?
    var icon: String?
    let options: [DropdownOption]
    let selected: String?
    var below = false
    /// As wide as it is given, as a field, its chevron at the far end.
    var fill = false
    let choose: (String) -> Void

    @Environment(\.dropdown) private var dropdown
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            dropdown.wrappedValue = Dropdown(anchor: frame, below: below, options: options,
                                             selected: selected, choose: choose)
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                if let site { Favicon(site: site, size: 14, plate: false) }
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(label)
                if fill { Spacer(minLength: 0) }
                if icon == nil {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: fill ? .infinity : nil)
        }
        .buttonStyle(SettingsButtonStyle())
        .fixedSize(horizontal: !fill, vertical: true)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Dropdown.space)) } action: { frame = $0 }
    }
}

/// The open list, on the menus' own panel. A click anywhere else or Esc puts it away.
private struct DropdownPanel: View {
    let dropdown: Dropdown
    let close: () -> Void

    /// The row under the pointer, the chosen one to begin with.
    @State private var lit: String?

    private static let rowHeight: CGFloat = 32
    private static let separatorHeight: CGFloat = 9

    var body: some View {
        GeometryReader { space in
            let lines = CGFloat(dropdown.options.count { $0.separated }) * Self.separatorHeight
            let panel = dropdown.panel
            let height = panel?.size.height ?? min(CGFloat(dropdown.options.count), 8.5) * Self.rowHeight + lines + 10
            let width = panel?.size.width ?? max(dropdown.anchor.width + 10, 200)
            let left = panel == nil ? dropdown.anchor.minX - 5 : dropdown.anchor.maxX - width
            let top = dropdown.below ? dropdown.anchor.maxY + 4 : dropdown.anchor.minY - 5
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                Group {
                    if let panel { panel.content } else { list }
                }
                .frame(width: width, height: height)
                .menuPanel()
                // Kept inside the settings, whichever edge it is near.
                .offset(x: max(8, min(left, space.size.width - width - 8)),
                        y: max(8, min(top, space.size.height - height - 8)))
            }
        }
        .background {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .onAppear { lit = dropdown.selected }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(dropdown.options, id: \.id) { option in
                        row(option)
                        if option.separated {
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                                .padding(.horizontal, 4)
                                .frame(height: Self.separatorHeight)
                        }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { if let selected = dropdown.selected { proxy.scrollTo(selected, anchor: .center) } }
        }
    }

    private func row(_ option: DropdownOption) -> some View {
        Button {
            close()
            dropdown.choose(option.id)
        } label: {
            HStack(spacing: 10) {
                if let site = option.site { Favicon(site: site, size: 16, plate: false) }
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 16)
                }
                Text(option.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if option.id == dropdown.selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit == option.id ? Palette.wash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { lit = option.id } }
        .id(option.id)
    }
}

/// Settings that belong together, on one card under their heading, with a
/// line between one and the next.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 12)
                    .padding(.top, 22)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        }
                        row
                    }
                }
            }
            .background(Color.primary.opacity(0.045))
            // A row lit under the pointer keeps to the card's corners.
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// One setting: what it is, a line on what it does, and its control at the
/// end; level with the top of a tall one (pictures to pick from).
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var icon: String?
    /// The icon's colour in place of the grey: a profile's.
    var tint: Color?
    var alignment = VerticalAlignment.center
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint ?? Palette.muted)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 13)
        .padding(.vertical, alignment == .top ? 12 : 0)
        .frame(minHeight: 52)
    }
}

/// Buttons on the settings' cards: outlined, or, for the one thing to do on a
/// card (checking for updates), filled in the text's colour; one that
/// deletes (`role: .destructive`), red on a wash of red.
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let destructive = configuration.role == .destructive
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? AnyShapeStyle(.red) : prominent ? AnyShapeStyle(Palette.ground) : AnyShapeStyle(Palette.ink))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(destructive ? AnyShapeStyle(Color.red.opacity(0.15))
                        : prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Color.primary.opacity(0.05)), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(prominent || destructive ? 0 : 0.12)))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(.green)
    }
}
