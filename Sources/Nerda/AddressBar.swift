import SwiftUI

/// Across the top of the page, level with the traffic lights: the sidebar's
/// button, back, forward and reload, then the address the rest of the way
/// across, the site in full and the rest of it dimmer. It wears the page's own
/// colour, with a hairline between it and the page. Clicked, or ⌘L, the
/// address becomes editable where it is; only suggestions, once typing
/// starts, hang below it. The page's colours fill the hairline as it loads.
struct AddressBar: View {
    let browser: Browser
    /// The tabs are across the top: no sidebar to toggle.
    var horizontal = false

    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 40
    private static let edge: CGFloat = 8
    private static let gap: CGFloat = 2

    /// The address, and the field it becomes when clicked, laid out alike so
    /// nothing moves between the two: height, inset, and the icon before the text.
    static let fieldHeight: CGFloat = 32
    static let fieldInset: CGFloat = 10
    static let fieldIcon: CGFloat = 14
    static let fieldSpacing: CGFloat = 8

    var body: some View {
        // The buttons find the tab when pressed rather than hold it: SwiftUI keeps
        // their actions a while after they go, and a tab held there keeps its page,
        // playing, after it is closed.
        let tab = browser.selected
        let loading = tab?.isLoading == true
        let color = tab?.color

        HStack(spacing: Self.gap) {
            if !horizontal {
                SidebarToggle(open: browser.sidebarOpen, toggle: browser.toggleSidebar)
                    .padding(.trailing, 4)
            }
            BarButton(icon: "chevron.left", help: "Back  ⌘[", enabled: tab?.canGoBack == true) {
                browser.selected?.webView.goBack()
            }
            BarButton(icon: "chevron.right", help: "Forward  ⌘]", enabled: tab?.canGoForward == true) {
                browser.selected?.webView.goForward()
            }
            BarButton(icon: loading ? "xmark" : "arrow.clockwise", help: loading ? "Stop" : "Reload  ⌘R",
                      enabled: tab?.hasPage == true) {
                guard let tab = browser.selected else { return }
                if tab.isLoading { tab.page?.stopLoading() } else { tab.reload() }
            }
            CopyButton(enabled: tab?.site != nil, copy: browser.copyLink)
            Group {
                if browser.editingAddress, let tab {
                    CommandBar(
                        text: tab.site?.absoluteString ?? "",
                        place: .address,
                        go: { url in
                            browser.selected?.go(to: url)
                            browser.endAddressEdit()
                        },
                        dismiss: browser.endAddressEdit,
                        requests: browser.commandBarRequests,
                        history: browser.history
                    )
                    // Another tab's address starts afresh.
                    .id(tab.id)
                } else {
                    AddressField(site: tab?.site, settings: tab?.settings, history: tab?.showsHistory == true,
                                 edit: browser.editAddress)
                }
            }
            .padding(.leading, 4)
            if !browser.isPrivate {
                ExtensionButtons(scheme: scheme)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, Self.edge)
        .frame(height: Self.height)
        // Moves the window, as the title bar under it would.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .titleBar()
        }
        // The card's upper corners; the lower are the page's.
        .background(Self.ground(of: tab), in: UnevenRoundedRectangle(
            topLeadingRadius: BrowserView.cornerRadius, topTrailingRadius: BrowserView.cornerRadius, style: .continuous
        ))
        // Light or dark to suit the page's colour, whatever the window's.
        .environment(\.colorScheme, color.map(Self.colorScheme) ?? scheme)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                // Just there: the page's own colour carries on under it.
                if tab?.settings == nil, tab?.showsHistory != true { Color.primary.opacity(0.06).frame(height: 1) }
                LoadLine(browser: browser)
            }
        }
    }

    /// What the bar wears, and the tab on screen across the top with it: the
    /// page's colour, or over a new tab or the settings, their own tinted glass.
    static func ground(of tab: Tab?) -> Color {
        if tab?.isBlank == true { return Palette.glass }
        if tab?.settings != nil || tab?.showsHistory == true { return Palette.panel }
        return tab?.color.map { Color(nsColor: $0) } ?? Palette.ground
    }

    /// What suits text on `color`: dark on a light page, light on a dark one.
    static func colorScheme(of color: NSColor) -> ColorScheme {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .dark }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5 ? .dark : .light
    }
}

/// Where the tab is, as a button across the rest of the bar that opens the
/// command bar on it: the site's icon, then the address.
private struct AddressField: View {
    let site: URL?
    /// On the settings, which have no address: where in them you are.
    var settings: SettingsPage?
    /// On the history page, which has no address either.
    var history = false
    let edit: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: edit) {
            HStack(spacing: AddressBar.fieldSpacing) {
                Group {
                    if let site {
                        Favicon(site: site, size: AddressBar.fieldIcon, plate: false)
                    } else {
                        Image(systemName: settings != nil ? "gearshape" : history ? "clock.arrow.circlepath" : "magnifyingglass")
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: AddressBar.fieldIcon)
                if let site {
                    let (name, rest) = Self.parts(of: site)
                    Text("\(Text(name).foregroundStyle(Palette.ink))\(Text(rest).foregroundStyle(Palette.muted))")
                    if site.scheme == "http" {
                        Text("Not Secure")
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Palette.hover, in: Capsule())
                    }
                } else if let settings {
                    Text("Settings").foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    Text(settings.title).foregroundStyle(Palette.ink)
                } else if history {
                    Text("History").foregroundStyle(Palette.ink)
                } else {
                    Text("Search or enter address")
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, AddressBar.fieldInset)
            .frame(height: AddressBar.fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the settings, only where you are: no click, no hover, and the
        // bar under it still moves the window.
        .allowsHitTesting(settings == nil)
        .accessibilityLabel(site?.absoluteString ?? (settings.map { "Settings, \($0.title)" } ?? (history ? "History" : "Search or enter address")))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    /// The site as it is typed (no scheme, no www.), and the rest of the
    /// address after it; an address without a site (file:) whole.
    static func parts(of url: URL) -> (site: String, rest: String) {
        guard let site = History.site(of: url) else { return (url.absoluteString, "") }
        var rest = url.path(percentEncoded: false)
        if rest == "/" { rest = "" }
        if let query = url.query(percentEncoded: false) { rest += "?" + query }
        if let fragment = url.fragment(percentEncoded: false) { rest += "#" + fragment }
        return (site, rest)
    }
}

/// Copies the tab's link, and turns to a tick for a moment after.
private struct CopyButton: View {
    let enabled: Bool
    let copy: () -> Void

    @State private var copied = false
    @State private var back: Task<Void, Never>?

    var body: some View {
        BarButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy Link", enabled: enabled) {
            copy()
            withAnimation { copied = true }
            back?.cancel()
            back = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation { copied = false }
            }
        }
        .contentTransition(.symbolEffect(.replace, options: .speed(2)))
    }
}

struct BarButton: View {
    let icon: String
    let help: String
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let lit = hovering && enabled
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(lit ? Palette.ink : Palette.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(lit ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: lit)
    }
}

/// Along the bar's bottom edge, filled from the left while the page loads, in
/// the site's own colours (Google's four, YouTube's red); in the text's
/// colour for a site whose icon has none.
private struct LoadLine: View {
    /// Read from here, not handed in by the bar: a load reports its progress
    /// many times, and only this line needs drawing again for it.
    let browser: Browser

    var body: some View {
        let tab = browser.selected
        let loading = tab?.isLoading == true
        let progress = tab?.progress ?? 0
        ZStack(alignment: .leading) {
            // Made anew for each load, so it starts from where that load is,
            // not shrinks back from where the last one ended.
            if loading {
                Rectangle()
                    .fill(LinearGradient(colors: colors(of: tab?.site), startPoint: .leading, endPoint: .trailing))
                    .scaleEffect(x: max(progress, 0.05), anchor: .leading)
                    .animation(.easeOut(duration: 0.25), value: progress)
                    .transition(.opacity)
            }
        }
        .frame(height: 2)
        .animation(.easeOut(duration: 0.3), value: loading)
        .allowsHitTesting(false)
    }

    private func colors(of site: URL?) -> [Color] {
        let tint = Favicons.origin(of: site).flatMap { Favicons.shared.tints[$0] }
        guard let tint, !tint.isGrey else { return [Palette.ink] }
        return tint.colors.map { Color(nsColor: $0) }
    }
}
