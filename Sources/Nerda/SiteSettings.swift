import SwiftUI
import WebKit

/// Permissions belong to an origin, including its scheme and port. Private
/// windows use an in-memory instance rather than the regular preferences.
@Observable
final class SiteSettings {
    static let shared = SiteSettings(defaults: .standard)
    enum Permission: String, Codable, CaseIterable, Identifiable {
        case ask, allow, block
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var decision: WKPermissionDecision {
            switch self { case .ask: .prompt; case .allow: .grant; case .block: .deny }
        }
    }
    struct Options: Codable, Equatable {
        var blocksAds = true
        var camera = Permission.ask
        var microphone = Permission.ask
        var location = Permission.ask
    }
    private var sites: [String: Options]
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        sites = defaults?.data(forKey: "siteSettings")
            .flatMap { try? JSONDecoder().decode([String: Options].self, from: $0) } ?? [:]
    }

    nonisolated static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func origin(_ origin: WKSecurityOrigin) -> String? {
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host
        if origin.port > 0 { parts.port = origin.port }
        return Self.origin(parts.url)
    }

    func options(for url: URL?) -> Options { Self.origin(url).flatMap { sites[$0] } ?? Options() }

    func set(_ options: Options, for url: URL) {
        guard let key = Self.origin(url) else { return }
        sites[key] = options == Options() ? nil : options
        defaults?.set(try? JSONEncoder().encode(sites), forKey: "siteSettings")
    }

    func mediaDecision(for origin: WKSecurityOrigin, on page: WKWebView, type: WKMediaCaptureType) -> WKPermissionDecision {
        let decision = Self.mediaDecision(options: options(for: page.url), type: type)
        // Block applies to the whole page. Embedded origins never inherit
        // the host page's permission to capture.
        guard decision != .deny, Self.origin(origin) != Self.origin(page.url) else { return decision }
        return .prompt
    }

    static func mediaDecision(options: Options, type: WKMediaCaptureType) -> WKPermissionDecision {
        let permissions: [Permission]
        switch type {
        case .camera: permissions = [options.camera]
        case .microphone: permissions = [options.microphone]
        case .cameraAndMicrophone: permissions = [options.camera, options.microphone]
        @unknown default: return .deny
        }
        if permissions.contains(.block) { return .deny }
        return permissions.allSatisfy { $0 == .allow } ? .grant : .prompt
    }

    static let blockingSelector = NSSelectorFromString("_setContentRuleListsEnabled:exceptions:")
    static let supportsSiteBlocking = WKWebpagePreferences().responds(to: blockingSelector)

    func applyBlocking(to preferences: WKWebpagePreferences, for url: URL?, lists: [WKContentRuleList] = Blocker.shared.rules) {
        // WebKit SPI, also used by Safari. It changes this document, even
        // when a popup shares its opener's content controller. Only Nerda's
        // lists are excepted; an extension's blocking stays its own.
        // Each navigation's preferences start with every list on: only an
        // exception needs the call.
        guard Self.supportsSiteBlocking, !options(for: url).blocksAds else { return }
        let exceptions = lists.compactMap(\.identifier)
        typealias SetRules = @convention(c) (AnyObject, Selector, Bool, NSSet) -> Void
        let call = unsafeBitCast(preferences.method(for: Self.blockingSelector), to: SetRules.self)
        call(preferences, Self.blockingSelector, true, NSSet(array: exceptions))
    }
}

extension Browser {
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard !locked else { return .deny }
        return siteSettings.mediaDecision(for: origin, on: webView, type: type)
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        locationDecision(origin, on: webView)
    }

    // The equivalent delegate on macOS 15.4–26 is SPI.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func locationPermission(_ page: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                            decision: @escaping (WKPermissionDecision) -> Void) {
        decision(locationDecision(origin, on: page))
    }

    private func locationDecision(_ origin: WKSecurityOrigin, on page: WKWebView) -> WKPermissionDecision {
        guard !locked else { return .deny }
        let decision = siteSettings.options(for: page.url).location.decision
        guard decision != .deny, SiteSettings.origin(origin) != SiteSettings.origin(page.url) else { return decision }
        return .prompt
    }

    func changeSiteOptions(_ options: SiteSettings.Options, for url: URL) {
        let previous = siteSettings.options(for: url)
        siteSettings.set(options, for: url)
        for tab in tabs where SiteSettings.origin(tab.site) == SiteSettings.origin(url) {
            // Revocation takes effect immediately, without a reload.
            if options.camera != .allow, previous.camera != options.camera {
                tab.page?.setCameraCaptureState(.none, completionHandler: nil)
            }
            if options.microphone != .allow, previous.microphone != options.microphone {
                tab.page?.setMicrophoneCaptureState(.none, completionHandler: nil)
            }
        }
    }
}

struct SiteControls: View {
    let browser: Browser
    let url: URL
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Site settings")
        .accessibilityLabel("Site settings")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 14) {
                Text(url.host() ?? "Site settings").font(.headline)
                Text(url.scheme == "https" ? "Connection uses HTTPS" : "Connection is not secure")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Block ads and trackers", isOn: binding(\.blocksAds))
                    .disabled(!SiteSettings.supportsSiteBlocking)
                if !Blocker.shared.isEnabled {
                    Text("Ad blocking is turned off in Settings.").font(.caption).foregroundStyle(.secondary)
                }
                permission("Camera", \.camera)
                permission("Microphone", \.microphone)
                permission("Location", \.location)
                Text("Camera, microphone and location also need macOS permission.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Reset site settings") { browser.changeSiteOptions(.init(), for: url) }
                    Spacer()
                    Button("Reload") { browser.selected?.reload(); shown = false }
                }
                Button("Clear site data…") {
                    guard let tab = browser.selected, SiteSettings.origin(tab.site) == SiteSettings.origin(url) else { return }
                    let alert = NSAlert()
                    alert.messageText = "Clear data for this site?"
                    alert.informativeText = "This may sign you out and remove offline data and drafts."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Clear")
                    guard let window = browser.window else { return }
                    alert.beginSheetModal(for: window) { answer in
                        if answer == .alertSecondButtonReturn { Task { await tab.clearSiteData() } }
                    }
                    shown = false
                }
            }
            .padding(18).frame(width: 320).popoverGlass()
        }
        .onChange(of: url) { shown = false }
    }

    private func binding<T>(_ key: WritableKeyPath<SiteSettings.Options, T>) -> Binding<T> {
        Binding(get: { browser.siteSettings.options(for: url)[keyPath: key] }, set: { value in
            var options = browser.siteSettings.options(for: url)
            options[keyPath: key] = value
            browser.changeSiteOptions(options, for: url)
        })
    }

    private func permission(_ title: String, _ key: WritableKeyPath<SiteSettings.Options, SiteSettings.Permission>) -> some View {
        Picker(title, selection: binding(key)) {
            ForEach(SiteSettings.Permission.allCases) { Text($0.title).tag($0) }
        }
    }
}
