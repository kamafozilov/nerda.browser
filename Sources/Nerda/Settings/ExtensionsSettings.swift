import SwiftUI
import WebKit

/// Chrome extensions: the two ways in (the Chrome Web Store, or a folder),
/// and what is installed, each turned on or off, set up or removed.
struct ExtensionsSettings: View {
    let browser: Browser

    @State private var link = ""
    @AppStorage(Extensions.enabledKey) private var enabled = false
    private var extensions: Extensions { .shared }

    var body: some View {
        SettingsGroup(title: "Extensions") {
            SettingsRow(title: "Enable extensions", detail: "Off by default for speed and reliability. Restart Nerda to apply", icon: "puzzlepiece.extension") {
                SettingsToggle(title: "Enable extensions", isOn: $enabled)
            }
        }
        SettingsGroup(title: "Add extensions") {
            SettingsLink(title: "Chrome Web Store", detail: "Find one, and press Add to Nerda on its page", icon: "bag") {
                browser.open(WebStore.home)
            }
            SettingsRow(title: "Add from a link", icon: "link") {
                HStack(spacing: 8) {
                    TextField("Store link or extension ID", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(add)
                    if extensions.busy != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add", action: add)
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(Crx.id(in: link) == nil)
                    }
                }
            }
        }
        SettingsGroup(title: "Installed") {
            if extensions.installed.isEmpty {
                SettingsRow(title: "No extensions yet", icon: "puzzlepiece.extension") { EmptyView() }
            }
            ForEach(extensions.installed) { item in
                InstalledRow(item: item)
            }
        }
        SettingsGroup(title: "Developer") {
            SettingsRow(title: "Load unpacked", detail: "A folder with a manifest.json. Reload picks up what you change in it", icon: "folder") {
                Button("Choose…", action: extensions.installFolder)
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    private func add() {
        guard Crx.id(in: link) != nil else { return }
        extensions.install(from: link)
        link = ""
    }
}

private struct InstalledRow: View {
    let item: InstalledExtension
    private var extensions: Extensions { .shared }

    var body: some View {
        let context = extensions.contexts[item.id]
        HStack(spacing: 12) {
            Group {
                if let icon = context?.webExtension.icon(for: CGSize(width: 40, height: 40)) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.muted)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(detail(context))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .help((extensions.errors[item.id] ?? []).joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            if context?.optionsPageURL != nil {
                Button("Options") { extensions.openOptions(item.id) }
                    .buttonStyle(SettingsButtonStyle())
            }
            Menu {
                Button(item.pinned == true ? "Unpin from Address Bar" : "Pin to Address Bar") {
                    extensions.setPinned(item.id, item.pinned != true)
                }
                if context?.overrideNewTabPageURL != nil {
                    let on = extensions.showsNewTab(item.id)
                    Button(on ? "Stop Showing in New Tabs" : "Show in New Tabs") { extensions.setShowsNewTab(item.id, !on) }
                }
                if item.source != nil || !item.fromStore { Button("Reload") { extensions.reload(item.id) } }
                if item.fromStore, let url = URL(string: "https://chromewebstore.google.com/detail/\(item.id)") {
                    Button("View in Chrome Web Store") { extensions.browser?.open(url) }
                }
                Divider()
                Button("Remove from Nerda…") { extensions.confirmRemove(item.id) }
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
            SettingsToggle(title: item.name, isOn: Binding(get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }))
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
    }

    private func detail(_ context: WKWebExtensionContext?) -> String {
        _ = extensions.settingsChanged
        var parts = ["Version \(item.version)", item.fromStore ? "Chrome Web Store"
                     : item.source.map { "From “\(URL(fileURLWithPath: $0).lastPathComponent)”" } ?? "From a folder"]
        if !Extensions.enabledAtLaunch { parts.append("paused") }
        else if item.enabled, context == nil { parts.append("couldn't start") }
        if context?.overrideNewTabPageURL != nil, extensions.showsNewTab(item.id) { parts.append("shows in new tabs") }
        let warnings = extensions.errors[item.id]?.count ?? 0
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts.joined(separator: " · ")
    }
}
