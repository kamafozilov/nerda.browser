import SwiftUI
import WebKit

/// At the address bar's right end, as in Chrome: the pinned extensions'
/// buttons, then the extensions button, whose list presses, pins and manages
/// them all, and leads to the Chrome Web Store. Not in incognito, where
/// extensions don't run.
struct ExtensionButtons: View {
    private var extensions: Extensions { .shared }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(extensions.buttons.filter(\.pinned)) { button in
                ExtensionActionButton(button: button) { extensions.press(button.id) }
                    .background(ExtensionAnchor(id: button.id))
                    .contextMenu { ExtensionActions(id: button.id) }
            }
            BarButton(icon: "puzzlepiece.extension", help: "Extensions") {
                extensions.menuOpen.toggle()
            }
            .background(ExtensionAnchor(id: Extensions.menuAnchor))
            .popover(isPresented: Bindable(extensions).menuOpen, arrowEdge: .bottom) {
                ExtensionMenu()
            }
        }
    }
}

/// An extension's button in the bar: its icon, and its badge.
private struct ExtensionActionButton: View {
    let button: Extensions.Button
    let press: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: press) {
            ExtensionIcon(button: button, size: 16)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(button.label)
        .accessibilityLabel(button.label)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// A view of AppKit's under a button, for a popup to hang from.
private struct ExtensionAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Extensions.shared.anchors[id] = WeakView(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Extensions.shared.anchors[id] = WeakView(view)
    }
}

/// An extension's icon, or its initial on a tile, with its badge in the corner.
struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = button.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                } else {
                    // Its initial, rather than a puzzle piece that would pass
                    // for the extensions button.
                    Text(button.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Palette.wash))
                }
            }
            .frame(width: size + 4, height: size + 4)
            .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                Text(button.badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }
}

/// What a right-click on an extension offers, in the bar and in the list.
private struct ExtensionActions: View {
    let id: String
    private var extensions: Extensions { .shared }

    var body: some View {
        let item = extensions.installed.first { $0.id == id }
        let pinned = item?.pinned ?? false
        Button(pinned ? "Unpin" : "Pin to Address Bar") { extensions.setPinned(id, !pinned) }
        if extensions.contexts[id]?.optionsPageURL != nil {
            Button("Options") { extensions.openOptions(id) }
        }
        if item?.source != nil { Button("Reload") { extensions.reload(id) } }
        Divider()
        Button("Remove from Nerda…") { extensions.confirmRemove(id) }
    }
}

/// The list behind the extensions button: every running extension, to press
/// and pin, and the ways to more.
private struct ExtensionMenu: View {
    private var extensions: Extensions { .shared }

    var body: some View {
        let buttons = extensions.buttons
        VStack(alignment: .leading, spacing: 0) {
            Text("Extensions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            // A store page whose own button Nerda couldn't find: the way in.
            if let id = WebStore.extensionID(on: extensions.browser?.selected?.site),
               !extensions.installed.contains(where: { $0.id == id }) {
                MenuRow(symbol: extensions.busy == id ? "hourglass" : "plus.circle", title: extensions.busy == id ? "Adding…" : "Add This Extension to Nerda") {
                    extensions.install(from: id)
                }
                .disabled(extensions.busy != nil)
                .padding(.horizontal, 6)
                Divider().padding(.horizontal, 12).padding(.vertical, 4)
            }
            if buttons.isEmpty {
                Text(extensions.installed.isEmpty ? "No extensions yet. Add them from the Chrome Web Store." : "None of your extensions is on.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(buttons) { ExtensionRow(button: $0) }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.horizontal, 12).padding(.vertical, 4)
            VStack(spacing: 2) {
                MenuRow(symbol: "bag", title: "Chrome Web Store") {
                    extensions.menuOpen = false
                    extensions.browser?.open(WebStore.home)
                }
                MenuRow(symbol: "gearshape", title: "Manage Extensions") {
                    extensions.menuOpen = false
                    extensions.browser?.openSettings(.extensions)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
    }
}

/// One extension in the list: pressed, as its button would be; pinned or
/// unpinned with the pin at its end.
private struct ExtensionRow: View {
    let button: Extensions.Button
    private var extensions: Extensions { .shared }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ExtensionIcon(button: button, size: 16)
            Text(button.name)
                .font(.system(size: 13))
                .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering || button.pinned {
                PinButton(pinned: button.pinned) { extensions.setPinned(button.id, !button.pinned) }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            // The list goes first; the popup, if there is one, then hangs
            // from the extensions button it came out of.
            extensions.menuOpen = false
            let id = button.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Extensions.shared.press(id) }
        }
        .onHover { hovering = $0 }
        .help(button.label)
        .contextMenu { ExtensionActions(id: button.id) }
    }
}

private struct PinButton: View {
    let pinned: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(pinned || hovering ? Palette.ink : Palette.muted)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(pinned ? "Unpin from Address Bar" : "Pin to Address Bar")
        .onHover { hovering = $0 }
    }
}

private struct MenuRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}
