import SwiftUI

/// What sites may do: what every site gets unless it has a choice of its
/// own, and each site that has, to change or reset. The same choices as
/// Site Settings beside the address.
struct SitePermissionsSettings: View {
    let browser: Browser
    private var settings: SiteSettings { browser.siteSettings }
    @State private var fallbacks = Dictionary(uniqueKeysWithValues: SiteSettings.Kind.allCases.map { ($0, $0.fallback) })
    @State private var offOnMac: Set<SiteSettings.Kind> = []

    var body: some View {
        SettingsGroup(title: "Permissions") {
            ForEach(Self.kinds) { kind in
                let fallback = fallbacks[kind] ?? .ask
                SettingsRow(title: kind.title, detail: detail(kind, fallback), icon: kind.symbol(fallback)) {
                    DropdownButton(label: fallback.title,
                                   options: [SiteSettings.Permission.ask, .block].map { DropdownOption(id: $0.rawValue, title: $0.title) },
                                   selected: fallback.rawValue) { choice in
                        let permission = SiteSettings.Permission(rawValue: choice) ?? .ask
                        fallbacks[kind] = permission
                        if permission == .ask { UserDefaults.standard.removeObject(forKey: kind.fallbackKey) }
                        else { UserDefaults.standard.set(permission.rawValue, forKey: kind.fallbackKey) }
                    }
                }
            }
        }
        .task { offOnMac = await SiteSettings.offOnMac() }
        SettingsGroup(title: "Sites") {
            let sites = settings.sites.compactMap { key, options in Self.address(key).map { (url: $0, options: options) } }
                .sorted { name($0.url).localizedStandardCompare(name($1.url)) == .orderedAscending }
            if sites.isEmpty {
                SettingsRow(title: "No sites yet", detail: "Sites you allow or block, when they ask or in Site Settings beside the address, are listed here",
                            icon: "globe") { EmptyView() }
            }
            ForEach(sites, id: \.url) { site in
                SiteRow(site: site.url, title: name(site.url), detail: summary(site.options)) {
                    menu(for: site.url)
                }
            }
        }
    }

    /// Notifications only where WebKit hands them over.
    private static var kinds: [SiteSettings.Kind] {
        SiteSettings.Kind.allCases.filter { $0 != .notifications || WebNotifications.isAvailable }
    }

    private func detail(_ kind: SiteSettings.Kind, _ fallback: SiteSettings.Permission) -> String {
        if offOnMac.contains(kind) { return "Off for Nerda in System Settings › Privacy & Security" }
        let what = kind.request.prefix(1).lowercased() + kind.request.dropFirst()
        return fallback == .block ? "Sites can't ask to \(what)" : "Sites ask before they \(what)"
    }

    /// A site's origin as an address, without the port its scheme goes to anyway.
    private static func address(_ origin: String) -> URL? {
        guard var parts = URLComponents(string: origin) else { return nil }
        if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.url
    }

    private func name(_ url: URL) -> String {
        let site = History.site(of: url) ?? url.host() ?? url.absoluteString
        return url.scheme == "http" ? "http://\(site)" : site
    }

    /// What is the site's own: "Camera allowed · Notifications blocked".
    private func summary(_ options: SiteSettings.Options) -> String {
        var parts = Self.kinds.compactMap { kind -> String? in
            switch options[keyPath: kind.key] {
            case .ask: nil
            case .allow: "\(kind.title) allowed"
            case .block: "\(kind.title) blocked"
            }
        }
        if options.allowsPopups { parts.append("Pop-ups allowed") }
        if !options.blocksAds { parts.append("Ads not blocked") }
        return parts.joined(separator: " · ")
    }

    /// Each permission to pick again, pop-ups, ads, and a way back to what every site gets.
    private func menu(for url: URL) -> some View {
        let options = settings.resolved(for: url)
        return Menu {
            ForEach(Self.kinds) { kind in
                Picker(kind.title, selection: Binding(get: { options[keyPath: kind.key] }, set: { change(kind.key, to: $0, for: url) })) {
                    ForEach(kind.choices) { Text($0.title).tag($0) }
                }
            }
            Picker("Pop-ups", selection: Binding(get: { options.allowsPopups }, set: { change(\.allowsPopups, to: $0, for: url) })) {
                Text(SiteSettings.Permission.allow.title).tag(true)
                Text(SiteSettings.Permission.block.title).tag(false)
            }
            Toggle("Block Ads and Trackers", isOn: Binding(get: { options.blocksAds }, set: { change(\.blocksAds, to: $0, for: url) }))
            Divider()
            Button("Reset Site Settings") { browser.changeSiteOptions(.init(), for: url) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(Palette.muted)
        .fixedSize()
        .accessibilityLabel("Settings for \(name(url))")
    }

    /// Through the window, which takes back what is no longer allowed at once.
    private func change<T>(_ key: WritableKeyPath<SiteSettings.Options, T>, to value: T, for url: URL) {
        var options = settings.options(for: url)
        options[keyPath: key] = value
        browser.changeSiteOptions(options, for: url)
    }
}
